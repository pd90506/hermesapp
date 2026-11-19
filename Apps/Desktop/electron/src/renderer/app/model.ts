import {
  DashboardConnector, GatewayConnection, GatewayEndpoint, Observable, describeError,
  type GatewayCredential,
} from '@talaria/hermes-core'
import type { Appearance, SavedServer, SavedSettings, TalariaBridge } from '../../shared/bridge.ts'
import { BridgeSocket, bridgeHttp } from './bridge-transport.ts'

export interface AppSnapshot {
  /** Settings are read; until then nothing is drawn. */
  loaded: boolean
  server?: SavedServer
  /** The connect page shows: no server yet, or the user opened it from the rail. */
  showsConnectPage: boolean
  railShown: boolean
  appearance: Appearance
  /** An error from the last connect attempt, shown on the connect page. */
  connectError?: string
  connecting: boolean
}

/** How a saved server signs in (HermesKit's `AuthMode.credential`). */
export function credential(server: SavedServer, secret: string): GatewayCredential {
  switch (server.authMode) {
    case 'password': return { kind: 'password', provider: server.provider || 'basic', username: server.username, password: secret }
    case 'accessToken': return { kind: 'bearer', accessToken: secret }
    case 'sessionToken': return { kind: 'sessionToken', token: secret }
  }
}

/**
 * The app's state above the connection: the saved server and its secret, the connect
 * page, the rail. Views read it and `connection` through `useSnapshot`.
 */
export class AppModel extends Observable<AppSnapshot> {
  readonly connection: GatewayConnection

  constructor(readonly bridge: TalariaBridge) {
    super({ loaded: false, showsConnectPage: false, railShown: true, appearance: { dark: false }, connecting: false })
    this.connection = new GatewayConnection({
      // Approval, sudo and secret get cards in the chat; any other request (clarify
      // until its card lands) is declined at once, so no agent waits on this window.
      client: { supportedServerRequests: new Set(['approval', 'sudo', 'secret']) },
    })
  }

  private update(change: Partial<AppSnapshot>): void {
    this.set({ ...this.get(), ...change })
  }

  /** Reads the settings and connects to the saved server, if there is one. */
  async start(): Promise<void> {
    const [settings, appearance] = await Promise.all([this.bridge.settings.load(), this.bridge.appearance.get()])
    this.bridge.appearance.onChange((next) => this.update({ appearance: next }))
    this.update({
      loaded: true,
      appearance,
      railShown: settings.railShown ?? true,
      showsConnectPage: !settings.server,
      ...(settings.server ? { server: settings.server } : {}),
    })
    if (!settings.server) return
    const secret = await this.bridge.secret.load()
    if (secret.value === null) {
      this.update({
        showsConnectPage: true,
        connectError: secret.available ? 'Enter the password or token again.' : 'The system keychain is locked.',
      })
      return
    }
    void this.open(settings.server, secret.value).catch(() => {})
  }

  /** Connects with what the connect page holds and, once connected, saves it. */
  async connect(server: SavedServer, secret: string): Promise<boolean> {
    this.update({ connecting: true })
    await this.bridge.http.reset()
    try {
      await this.open(server, secret)
    } catch (error) {
      this.update({ connecting: false, connectError: describeError(error) })
      return false
    }
    await this.save({ server })
    await this.bridge.secret.save(secret)
    this.update({ server, connecting: false, connectError: undefined, showsConnectPage: false })
    return true
  }

  private async open(server: SavedServer, secret: string): Promise<void> {
    const endpoint = new GatewayEndpoint(server.serverURL)
    const connector = new DashboardConnector(endpoint, credential(server, secret), bridgeHttp(this.bridge),
      (url) => new BridgeSocket(this.bridge, url))
    await this.connection.connect(connector)
  }

  /** Disconnects and forgets the server and its secret. */
  async forgetServer(): Promise<void> {
    await this.connection.disconnect()
    await this.bridge.secret.save(null)
    await this.bridge.http.reset()
    const { server: _, ...rest } = await this.bridge.settings.load()
    await this.bridge.settings.save(rest)
    this.set({ ...this.get(), server: undefined, showsConnectPage: true, connectError: undefined })
  }

  showConnectPage(shown: boolean): void {
    this.update({ showsConnectPage: shown, connectError: undefined })
  }

  toggleRail(): void {
    const railShown = !this.get().railShown
    this.update({ railShown })
    void this.save({ railShown })
  }

  private async save(change: Partial<SavedSettings>): Promise<void> {
    const settings = await this.bridge.settings.load()
    await this.bridge.settings.save({ ...settings, ...change })
  }
}
