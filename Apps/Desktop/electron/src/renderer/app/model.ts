import {
  DashboardConnector, GatewayConnection, Observable, ServerRegistry, decodeAlertPreferences, decodeSourceSettings,
  defaultAlertPreferences, defaultSourceSettings, type AlertPreferences, type ServerConfig, type ServerEntry,
  type SessionSourceSettings,
} from '@talaria/hermes-core'
import type { Appearance, SavedServer, SavedSettings, TalariaBridge } from '../../shared/bridge.ts'
import { BridgeSocket, bridgeHttp } from './bridge-transport.ts'

export interface AppSnapshot {
  /** Settings are read; until then nothing is drawn. */
  loaded: boolean
  /** The current server's settings (the server of the profile picked in the rail). */
  server?: ServerConfig
  /** The server whose profiles and sessions the sidebar shows; `model.connection` is its connection. */
  currentServerID?: string
  /** The first-run page: no server to connect to yet. */
  showsConnectPage: boolean
  railShown: boolean
  appearance: Appearance
  /** An error from the first-run page's connect. */
  connectError?: string
  connecting: boolean
  /** Settings (the overlay): whether it is open, and the pane it shows. */
  settings: { open: boolean; pane: string }
  /** Settings ▸ Session Sources. */
  sourceSettings: SessionSourceSettings
  /** Settings ▸ Notifications. */
  alertPreferences: AlertPreferences
}

/**
 * The app's state above the connections: the servers (`ServerRegistry`, one connection
 * each), which of them the sidebar shows, the first-run page, the rail, the Settings
 * window and the app's own settings. Views read it through `useSnapshot`, and the current
 * server's connection through `useConnection` (app/hooks.ts).
 */
export class AppModel extends Observable<AppSnapshot> {
  readonly servers: ServerRegistry
  /** A connection that is never connected, while there is no server. */
  private readonly idle = this.makeConnection()

  constructor(readonly bridge: TalariaBridge) {
    super({
      loaded: false, showsConnectPage: false, railShown: true, appearance: { dark: false }, connecting: false,
      settings: { open: false, pane: 'servers' }, sourceSettings: defaultSourceSettings,
      alertPreferences: defaultAlertPreferences,
    })
    const http = bridgeHttp(bridge)
    this.servers = new ServerRegistry({
      platform: bridge.platform,
      makeID: () => globalThis.crypto.randomUUID(),
      makeConnection: () => {
        const connection = this.makeConnection()
        connection.setSourceSettings(this.get().sourceSettings)
        return connection
      },
      makeConnector: (endpoint, credential) =>
        new DashboardConnector(endpoint, credential, http, (url) => new BridgeSocket(bridge, url)),
      http,
      saveServers: (servers, localBackend) => this.save({ servers, localBackend }),
      loadSecret: (id) => bridge.secrets.load(id),
      saveSecret: (id, value) => bridge.secrets.save(id, value),
      signIn: {
        listen: async () => {
          const { id, port } = await bridge.signIn.listen()
          return { port, callback: bridge.signIn.callback(id), stop: () => void bridge.signIn.stop(id) }
        },
        openExternal: (url) => bridge.signIn.openExternal(url),
      },
      localBackend: bridge.localBackend,
    })
    this.servers.subscribe(() => this.followServers())
  }

  /** A server's connection. A, chats: keep the server id a chat belongs to and use this. */
  protected makeConnection(): GatewayConnection {
    return new GatewayConnection({
      // No approval or clarify cards yet: every server request is declined at once,
      // so no agent waits on this window (4404 for the window-owned bridges).
      client: { supportedServerRequests: new Set<string>() },
    })
  }

  private update(change: Partial<AppSnapshot>): void {
    this.set({ ...this.get(), ...change })
  }

  /** The current server's connection (an idle one while there is none). */
  get connection(): GatewayConnection {
    return this.servers.server(this.get().currentServerID)?.connection ?? this.idle
  }

  /** A server's connection, by its id. */
  serverConnection(id: string | undefined): GatewayConnection | undefined {
    return this.servers.server(id)?.connection
  }

  /** The current server. */
  get currentServer(): ServerEntry | undefined {
    return this.servers.server(this.get().currentServerID)
  }

  /** Reads the settings and connects to the saved servers. */
  async start(): Promise<void> {
    const [settings, appearance] = await Promise.all([this.bridge.settings.load(), this.bridge.appearance.get()])
    this.bridge.appearance.onChange((next) => this.update({ appearance: next }))
    this.bridge.settingsWindow.onOpenRequest(() => this.openSettings())
    const sourceSettings = decodeSourceSettings(settings.sourceSettings)
    this.update({
      appearance,
      railShown: settings.railShown ?? true,
      sourceSettings,
      alertPreferences: decodeAlertPreferences(settings.alertPreferences),
      settings: { open: false, pane: settings.settingsPane ?? 'servers' },
    })
    // The first desktop version's single server, its secret in `server-secret.bin`.
    await this.servers.load(settings, async () => (await this.bridge.secret.load()).value)
    if (settings.server && !Array.isArray(settings.servers)) {
      // Moved into `servers` (saved by the load) and `secrets/<id>.bin`.
      this.saving = this.saving.then(async () => {
        const { server: _, ...rest } = await this.bridge.settings.load()
        await this.bridge.settings.save(rest)
        await this.bridge.secret.save(null)
      }).catch(() => {})
    }
    this.update({ loaded: true })
    this.followServers()
    this.servers.connectAll()
    // A server that can't connect at launch: its settings show why.
    if (this.servers.sidebarServers.some((entry) => !entry.isLocal && !entry.hasSecret)) this.openSettings('servers')
  }

  /** The first-run page's Connect: adds the server, connects, and keeps it once connected. */
  async connect(server: SavedServer, secret: string): Promise<boolean> {
    this.update({ connecting: true, connectError: undefined })
    const id = this.servers.add({ ...server })
    this.servers.setSecret(id, secret)
    const connected = await this.servers.connect(id)
    if (!connected) {
      this.update({ connecting: false, connectError: this.servers.server(id)?.lastError })
      return false
    }
    this.update({ connecting: false, currentServerID: id })
    return true
  }

  /** Picks a profile in the rail: the sidebar shows that server and profile. */
  selectProfile(serverID: string, profile: string): void {
    const entry = this.servers.server(serverID)
    if (!entry) return
    if (this.get().currentServerID !== serverID) this.update({ currentServerID: serverID, server: entry.config })
    entry.connection.selectProfile(profile)
  }

  /** Opens Settings, at `pane` when given. */
  openSettings(pane?: string): void {
    const settings = this.get().settings
    this.update({ settings: { open: true, pane: pane ?? settings.pane } })
    if (pane && pane !== settings.pane) void this.save({ settingsPane: pane })
  }

  /** Closes Settings. */
  closeSettings(): void {
    this.update({ settings: { ...this.get().settings, open: false } })
  }

  selectSettingsPane(pane: string): void {
    if (pane === this.get().settings.pane) return
    this.update({ settings: { ...this.get().settings, pane } })
    void this.save({ settingsPane: pane })
  }

  setSourceSettings(sourceSettings: SessionSourceSettings): void {
    this.update({ sourceSettings })
    for (const entry of this.servers.get().servers) entry.connection.setSourceSettings(sourceSettings)
    void this.save({ sourceSettings })
  }

  setAlertPreferences(alertPreferences: AlertPreferences): void {
    this.update({ alertPreferences })
    void this.save({ alertPreferences })
  }

  /** Disconnects and forgets the current server (the first-run page's Forget). */
  async forgetServer(): Promise<void> {
    const id = this.get().currentServerID
    if (id) await this.servers.remove(id)
  }

  showConnectPage(shown: boolean): void {
    if (!shown) this.update({ connectError: undefined })
    // The rail's Settings button opens Settings now.
    if (shown) this.openSettings('servers')
  }

  toggleRail(): void {
    const railShown = !this.get().railShown
    this.update({ railShown })
    void this.save({ railShown })
  }

  /** Keeps the current server valid as servers come and go, and the first-run page. */
  private followServers(): void {
    if (!this.get().loaded) return
    const sidebar = this.servers.sidebarServers
    const snapshot = this.servers.get()
    let currentServerID = this.get().currentServerID
    if (!sidebar.some((entry) => entry.id === currentServerID)) currentServerID = sidebar[0]?.id
    const server = sidebar.find((entry) => entry.id === currentServerID)?.config
    const showsConnectPage = sidebar.length === 0 && !snapshot.runsLocalBackend
    const current = this.get()
    if (current.currentServerID === currentServerID && current.server === server && current.showsConnectPage === showsConnectPage) return
    this.update({ currentServerID, server, showsConnectPage })
  }

  private saving: Promise<void> = Promise.resolve()

  /** Saves a change to settings.json, one write after another. */
  private save(change: Partial<SavedSettings>): Promise<void> {
    this.saving = this.saving.then(async () => {
      const settings = await this.bridge.settings.load()
      await this.bridge.settings.save({ ...settings, ...change })
    }).catch(() => {})
    return this.saving
  }
}
