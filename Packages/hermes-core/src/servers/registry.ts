import type { GatewayConnection } from '../connection.ts'
import type { GatewayConnector, GatewayCredential } from '../connector.ts'
import { DashboardClient } from '../dashboard.ts'
import { describeError } from '../describe.ts'
import { GatewayEndpoint } from '../endpoint.ts'
import type { HttpClient } from '../http.ts'
import { Observable } from '../observable.ts'
import {
  authModeCopy, hasServerURL, loadServerList, newServerConfig, serverCredential, serverDisplayName,
  type ServerConfig,
} from './config.ts'
import { localServerID, type LocalPlatform, localServerName } from './local-backend.ts'
import { NativeSignIn, NativeSignInError } from './native-sign-in.ts'
import { NativeTokenSession, nativeTokensFromSecret, nativeTokensSecret, refreshRejectedReason } from './native-tokens.ts'

/** One server as the views see it (HermesKit's `ServerConnection`). Replaced on every change. */
export interface ServerEntry {
  /** `config.id`, which never changes. */
  readonly id: string
  readonly config: ServerConfig
  /** `config`'s name, or one derived from its URL. */
  readonly name: string
  /** Its own connection: profiles, sessions and chats of this server. */
  readonly connection: GatewayConnection
  /** The Hermes the app runs on this computer ("This Mac" / "This PC"). */
  readonly isLocal: boolean
  /** Something to connect to: an address, or the local backend. */
  readonly hasURL: boolean
  /** A password, token or browser sign-in is there (kept, or typed since). */
  readonly hasSecret: boolean
  /** The browser sign-in's pair is there. */
  readonly isSignedInWithBrowser: boolean
  readonly connecting: boolean
  /** A browser sign-in is waiting for the browser. */
  readonly signingIn: boolean
  readonly lastError?: string
  /** Check Server's answer. */
  readonly probeResult?: string
}

export interface ServersSnapshot {
  /** Settings were read. */
  readonly loaded: boolean
  readonly servers: readonly ServerEntry[]
  /** Whether the app runs Hermes on this computer. */
  readonly runsLocalBackend: boolean
}

/** The app's side of the registry: storage, transports and the main process's helpers. */
export interface ServerHost {
  platform: LocalPlatform
  makeID(): string
  makeConnection(): GatewayConnection
  /** A connector for an endpoint and a credential (the app's HTTP and sockets). */
  makeConnector(endpoint: GatewayEndpoint, credential: GatewayCredential): GatewayConnector
  /** HTTP for Check Server and the browser sign-in. */
  http: HttpClient
  saveServers(servers: ServerConfig[], runsLocalBackend: boolean): Promise<void>
  loadSecret(id: string): Promise<{ value: string | null; available: boolean }>
  saveSecret(id: string, value: string | null): Promise<void>
  /** The browser sign-in's loopback listener and the system browser. */
  signIn?: {
    listen(): Promise<{ port: number; callback: Promise<string>; stop(): void }>
    openExternal(url: string): Promise<void>
  }
  /** The `hermes serve` this app runs, when it can. */
  localBackend?: {
    /** Whether a `hermes` executable is installed. */
    available(): Promise<boolean>
    start(): Promise<{ port: number; token: string }>
    stop(): Promise<void>
    isRunning(): Promise<boolean>
  }
}

interface ServerRecord {
  config: ServerConfig
  secret: string
  /** The browser sign-in's token session, shared by every connect of this server. */
  nativeSession?: NativeTokenSession
  connection: GatewayConnection
  isLocal: boolean
  connecting: boolean
  signingIn: boolean
  lastError?: string
  probeResult?: string
  unsubscribe: () => void
}

export interface SavedServerSettings {
  servers?: unknown
  /** The single server of the first desktop version. */
  server?: unknown
  localBackend?: boolean
}

/**
 * The servers the app knows, each with its own connection (HermesKit's `AppModel`
 * server list): add, edit, remove, connect, Check Server, browser sign-in, and the
 * Hermes the app runs on this computer. Saved through `ServerHost`.
 */
export class ServerRegistry extends Observable<ServersSnapshot> {
  private records: ServerRecord[] = []
  private runsLocal = false

  constructor(private readonly host: ServerHost) {
    super({ loaded: false, servers: [], runsLocalBackend: false })
  }

  /** Reads the saved servers and their secrets. `legacySecret` is the first version's single secret. */
  async load(settings: SavedServerSettings, legacySecret?: () => Promise<string | null>): Promise<void> {
    const { servers, migrated } = loadServerList(settings, () => this.host.makeID())
    const records: ServerRecord[] = []
    for (const config of servers) {
      let secret = (await this.host.loadSecret(config.id)).value ?? ''
      if (migrated && config.id === migrated.id && legacySecret) {
        secret = (await legacySecret()) ?? ''
        if (secret) await this.host.saveSecret(config.id, secret)
      }
      records.push(this.makeRecord(config, secret, false))
    }
    this.records = records
    this.runsLocal = settings.localBackend ?? false
    if (this.runsLocal && this.host.localBackend) this.records.unshift(this.makeLocalRecord())
    if (migrated) await this.save()
    this.publish(true)
  }

  /** At launch: connects every server with an address and a secret. */
  connectAll(): void {
    for (const record of this.records) {
      if (record.isLocal || (hasServerURL(record.config) && record.secret)) void this.connect(record.config.id)
    }
  }

  server(id: string | undefined): ServerEntry | undefined {
    return id === undefined ? undefined : this.get().servers.find((entry) => entry.id === id)
  }

  /** The servers the sidebar shows: those with an address. */
  get sidebarServers(): ServerEntry[] {
    return this.get().servers.filter((entry) => entry.hasURL)
  }

  /** A blank server for the settings (the one already there, if any). */
  add(change: Partial<Omit<ServerConfig, 'id'>> = {}): string {
    const blank = this.records.find((record) => !record.isLocal && !hasServerURL(record.config))
    if (blank) {
      blank.config = { ...blank.config, ...change }
      this.publish()
      return blank.config.id
    }
    const record = this.makeRecord(newServerConfig(this.host.makeID(), change), '', false)
    this.records.push(record)
    this.publish()
    return record.config.id
  }

  /** Edits a server's settings (saved with the next connect, as on the Mac). */
  update(id: string, change: Partial<Omit<ServerConfig, 'id'>>): void {
    const record = this.record(id)
    if (!record || record.isLocal) return
    record.config = { ...record.config, ...change }
    record.probeResult = undefined
    this.publish()
  }

  /** The password or token typed in the settings (saved with the next connect). */
  setSecret(id: string, secret: string): void {
    const record = this.record(id)
    if (!record || record.isLocal || record.secret === secret) return
    record.secret = secret
    record.nativeSession = undefined
    this.publish()
  }

  /** Disconnects and forgets a server, its secret included. */
  async remove(id: string): Promise<void> {
    const record = this.record(id)
    if (!record) return
    if (record.isLocal) return this.setRunsLocalBackend(false)
    this.records = this.records.filter((candidate) => candidate !== record)
    record.unsubscribe()
    this.publish()
    await this.save()
    await this.host.saveSecret(id, null)
    await record.connection.disconnect()
  }

  /** Connects (or reconnects) a server, saving its settings and secret first. */
  async connect(id: string): Promise<boolean> {
    const record = this.record(id)
    if (!record || record.connecting) return false
    record.lastError = undefined
    const name = serverDisplayName(record.config)
    if (!record.isLocal && !record.secret) {
      record.lastError = record.config.authMode === 'browser'
        ? `${name} isn’t signed in. Use Sign In in Settings.`
        : `No ${authModeCopy[record.config.authMode].secretLabel.toLowerCase()} for ${name}. Enter it in Settings.`
      this.publish()
      return false
    }
    record.connecting = true
    this.publish()
    try {
      if (record.isLocal) {
        const backend = this.host.localBackend
        if (!backend) throw new Error('This app can’t run Hermes here.')
        // A new port and token each time it starts.
        const running = await backend.start()
        record.config = { ...record.config, serverURL: `http://127.0.0.1:${running.port}` }
        record.secret = running.token
      }
      const endpoint = new GatewayEndpoint(record.config.serverURL)
      if (!record.isLocal) {
        await this.save()
        await this.host.saveSecret(id, record.secret).catch((error: unknown) => {
          // Still connect with the secret in memory, but say it won't survive a relaunch.
          record.lastError = describeError(error)
        })
      }
      await record.connection.connect(this.host.makeConnector(endpoint, this.credential(record)))
      return true
    } catch (error) {
      if (this.record(id) === record) record.lastError = this.describe(error, record)
      return false
    } finally {
      record.connecting = false
      this.publish()
    }
  }

  async disconnect(id: string): Promise<void> {
    const record = this.record(id)
    if (!record) return
    await record.connection.disconnect()
    if (record.isLocal) await this.host.localBackend?.stop()
    this.publish()
  }

  /** Check Server: the dashboard's public `/api/status` (HermesKit's `AppModel.probe`). */
  async probe(id: string): Promise<void> {
    const record = this.record(id)
    if (!record) return
    record.probeResult = undefined
    this.publish()
    let result: string
    try {
      const status = await new DashboardClient(new GatewayEndpoint(record.config.serverURL), this.host.http).status()
      const parts = [`Hermes ${status.version ?? '?'}`]
      parts.push(status.auth_required ? `sign-in required (${(status.auth_flows ?? []).join(', ')})` : 'no sign-in required')
      result = parts.join(' · ')
    } catch (error) {
      result = `Unreachable: ${describeError(error)}`
    }
    if (this.record(id) !== record) return
    record.probeResult = result
    this.publish()
  }

  /**
   * Signs a server in in the browser (`NativeSignIn`): listens on the loopback, opens the
   * dashboard's sign-in page in the system browser, trades the code it comes back with for
   * a token pair, keeps the pair as the server's secret and connects. Aborting `signal`
   * (Cancel, or the settings closing) stops waiting.
   */
  async signInWithBrowser(id: string, signal?: { addEventListener(type: 'abort', listener: () => void): void }): Promise<void> {
    const record = this.record(id)
    const helper = this.host.signIn
    if (!record || !helper || record.signingIn) return
    record.lastError = undefined
    record.signingIn = true
    this.publish()
    let listener: Awaited<ReturnType<typeof helper.listen>> | undefined
    try {
      const endpoint = new GatewayEndpoint(record.config.serverURL)
      listener = await helper.listen()
      const signIn = new NativeSignIn(endpoint, listener.port, this.host.http)
      await helper.openExternal(signIn.authorizeURL)
      const aborted = new Promise<never>((_, reject) => {
        const timer = setTimeout(() => reject(new SignInCancelled()), 600_000)
        signal?.addEventListener('abort', () => {
          clearTimeout(timer)
          reject(new SignInCancelled())
        })
      })
      const callback = await Promise.race([listener.callback, aborted])
      const tokens = await signIn.tokens(callback)
      if (this.record(id) !== record) return
      record.config = { ...record.config, authMode: 'browser' }
      record.secret = nativeTokensSecret(tokens)
      record.nativeSession = undefined
      record.signingIn = false
      this.publish()
      await this.connect(id)
    } catch (error) {
      if (!(error instanceof SignInCancelled)) record.lastError = describeSignIn(error)
    } finally {
      listener?.stop()
      record.signingIn = false
      this.publish()
    }
  }

  /** Turns the local backend on (started and connected) or off (stopped and removed). */
  async setRunsLocalBackend(on: boolean): Promise<void> {
    if (!this.host.localBackend) return
    this.runsLocal = on
    const existing = this.records.find((record) => record.isLocal)
    if (on && !existing) {
      this.records.unshift(this.makeLocalRecord())
      this.publish()
      await this.save()
      await this.connect(localServerID)
    } else if (!on && existing) {
      this.records = this.records.filter((record) => record !== existing)
      existing.unsubscribe()
      this.publish()
      await this.save()
      await existing.connection.disconnect()
      await this.host.localBackend.stop()
    } else {
      this.publish()
      await this.save()
    }
  }

  /** The backend died (crashed, stopped, updated): starts a new one, instead of retrying a dead port. */
  async reviveLocalBackend(): Promise<void> {
    const record = this.records.find((candidate) => candidate.isLocal)
    if (!record || record.connecting || !this.host.localBackend) return
    const phase = record.connection.get().link.phase
    if ((phase === 'reconnecting' || phase === 'failed') && !(await this.host.localBackend.isRunning())) {
      await this.connect(record.config.id)
    }
  }

  private credential(record: ServerRecord): GatewayCredential {
    if (record.config.authMode !== 'browser') return serverCredential(record.config, record.secret)
    if (!record.nativeSession) {
      const tokens = nativeTokensFromSecret(record.secret) ?? { access_token: '', refresh_token: '' }
      const id = record.config.id
      record.nativeSession = new NativeTokenSession(tokens, async (fresh) => {
        record.secret = nativeTokensSecret(fresh)
        await this.host.saveSecret(id, record.secret).catch(() => {})
      })
    }
    return { kind: 'native', session: record.nativeSession }
  }

  private describe(error: unknown, record: ServerRecord): string {
    const message = error instanceof Error && 'reason' in error && error.reason === refreshRejectedReason
      ? 'The browser sign-in ended. Sign in again in Settings.'
      : describeError(error)
    return this.sidebarServers.length > 1 ? `${serverDisplayName(record.config)}: ${message}` : message
  }

  private record(id: string): ServerRecord | undefined {
    return this.records.find((record) => record.config.id === id)
  }

  private makeRecord(config: ServerConfig, secret: string, isLocal: boolean): ServerRecord {
    const connection = this.host.makeConnection()
    const record: ServerRecord = {
      config, secret, connection, isLocal, connecting: false, signingIn: false, unsubscribe: () => {},
    }
    // The settings show each server's status: a change of its link is a change here.
    let phase = connection.get().link
    record.unsubscribe = connection.subscribe(() => {
      const link = connection.get().link
      if (link === phase) return
      phase = link
      this.publish()
    })
    return record
  }

  private makeLocalRecord(): ServerRecord {
    const config = newServerConfig(localServerID, { name: localServerName(this.host.platform), authMode: 'sessionToken' })
    return this.makeRecord(config, '', true)
  }

  private async save(): Promise<void> {
    // A server without an address isn't one yet; the local one is made at every launch.
    const configs = this.records.filter((record) => !record.isLocal && hasServerURL(record.config)).map((record) => record.config)
    await this.host.saveServers(configs, this.runsLocal)
  }

  private publish(loaded = this.get().loaded): void {
    this.set({
      loaded,
      runsLocalBackend: this.runsLocal,
      servers: this.records.map((record): ServerEntry => {
        const entry: ServerEntry = {
          id: record.config.id,
          config: record.config,
          name: serverDisplayName(record.config),
          connection: record.connection,
          isLocal: record.isLocal,
          hasURL: record.isLocal || hasServerURL(record.config),
          hasSecret: record.secret !== '',
          isSignedInWithBrowser: record.config.authMode === 'browser' && nativeTokensFromSecret(record.secret) !== undefined,
          connecting: record.connecting,
          signingIn: record.signingIn,
          ...(record.lastError !== undefined ? { lastError: record.lastError } : {}),
          ...(record.probeResult !== undefined ? { probeResult: record.probeResult } : {}),
        }
        return entry
      }),
    })
  }
}

class SignInCancelled extends Error {
  constructor() {
    super('cancelled')
  }
}

/** A browser sign-in's failure, as the Mac's `AppModel.describeSignIn`. */
function describeSignIn(error: unknown): string {
  if (error instanceof NativeSignInError) {
    if (error.kind === 'refused') return `The sign-in was refused: ${error.message}`
    return error.message
  }
  return describeError(error)
}
