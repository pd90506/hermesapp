import { Bot, historyRows, type ProfileRow, type SessionSummary } from './bots.ts'
import { GatewayClient, GatewayClientError, type GatewayClientConfiguration, type GatewayReady } from './client.ts'
import type { GatewayConnector } from './connector.ts'
import { DashboardError } from './dashboard.ts'
import { dashboardAPIFor, type DashboardAPI } from './dashboard-api.ts'
import { describeError } from './describe.ts'
import { Observable } from './observable.ts'
import { EventType, GatewayMethod } from './protocol/methods.ts'
import type { JSONValue } from './protocol/jsonrpc.ts'
import { ChatManager } from './session/chats.ts'
import { ConnectionAlerts } from './session/background/system-alerts.ts'
import { messagesSource } from './session/messages-source.ts'
import { defaultSourceSettings, showsSource, type SessionSourceSettings } from './settings/sources.ts'

export type LinkState =
  | { phase: 'disconnected' }
  | { phase: 'connecting' }
  | { phase: 'connected' }
  | { phase: 'reconnecting'; attempt: number }
  | { phase: 'failed'; message: string }

/** Everything the sidebar paints from. Replaced as a whole on every change. */
export interface ConnectionSnapshot {
  link: LinkState
  /**
   * The connection has been trying (`connecting`, `reconnecting`) for longer than
   * `tryingNoticeDelayMs`: only then do the apps show it (the user, 2026-10-19).
   */
  isTryingNoticeably: boolean
  /** Every profile as a bot, `default` first. */
  bots: readonly Bot[]
  /** The profile whose sessions the list shows. */
  selectedProfile?: string
  /** Listed sessions by profile: listed sources only, never the bot's own chat. */
  sessions: Readonly<Record<string, readonly SessionSummary[]>>
  sessionListLoading: boolean
  sessionListError?: string
}

const initial: ConnectionSnapshot = {
  link: { phase: 'disconnected' },
  isTryingNoticeably: false,
  bots: [],
  sessions: {},
  sessionListLoading: false,
}

/** 0.5 s, 1 s, 2 s, ... capped at 30 s, with 20 % jitter (HermesKit's `exponentialBackoff`). */
export function exponentialBackoff(attempt: number, random: () => number = Math.random): number {
  const base = Math.min(30, 0.5 * 2 ** Math.max(0, attempt - 1))
  return Math.round(base * (0.8 + 0.4 * random()) * 1000)
}

export interface GatewayConnectionOptions {
  client?: Partial<GatewayClientConfiguration>
  backoff?: (attempt: number) => number
  tryingNoticeDelayMs?: number
  /** Gives up after this many failed reconnects; undefined retries forever. */
  maxReconnectAttempts?: number
}

/**
 * One server's connection, profiles and session lists (HermesKit's `GatewayConnection`,
 * the parts this version of the desktop app shows). A dropped socket reconnects with
 * backoff on a fresh ticket; a rejected sign-in stops and reports it.
 */
export class GatewayConnection extends Observable<ConnectionSnapshot> {
  private client?: GatewayClient
  private connector?: GatewayConnector
  private generation = 0
  private reconnecting = false
  private tryingTimer?: ReturnType<typeof setTimeout>
  private listsRefresh?: Promise<void>
  private listsRefreshQueued = false
  private sessionListToken = 0
  /** The `session.list` limit that settled, per profile. */
  private readonly sessionListLimits = new Map<string, number>()
  /** Settings ▸ Session Sources: which listed sources the lists hide. */
  private sourceSettings: SessionSourceSettings = defaultSourceSettings
  private readonly options: Required<Omit<GatewayConnectionOptions, 'client' | 'maxReconnectAttempts'>> &
    Pick<GatewayConnectionOptions, 'client' | 'maxReconnectAttempts'>

  /** This server's chats (package A): open, warm, re-bound after a reconnect. */
  readonly chats: ChatManager
  /** This server's system notifications (package J). */
  readonly alerts: ConnectionAlerts

  constructor(options: GatewayConnectionOptions = {}) {
    super(initial)
    const connection = this
    this.chats = new ChatManager({
      get client() { return connection.client },
      get messagesSource() {
        if (connection.connector?.messagesSource) return connection.connector.messagesSource
        const api = dashboardAPIFor(connection.connector)
        return api ? messagesSource(api) : undefined
      },
      get generation() { return connection.generation },
      get bots() { return connection.get().bots },
      refreshLists: () => this.refreshListsInBackground(),
      backgroundFinished: (chat, process) => this.alerts.backgroundFinished(chat, process),
    })
    this.alerts = new ConnectionAlerts({
      get client() { return connection.client },
      get active() { return connection.chats.active },
      get warm() { return connection.chats.warm },
      get bots() { return connection.get().bots },
      sessionRow: (profile, id) => this.get().sessions[profile]?.find((row) => row.id === id),
      get otherRequests() { return connection.chats.get().otherRequests },
      dropOtherRequest: (id) => this.chats.dropOtherRequest(id),
    })
    this.options = {
      backoff: options.backoff ?? ((attempt) => exponentialBackoff(attempt)),
      tryingNoticeDelayMs: options.tryingNoticeDelayMs ?? 5000,
      ...(options.client ? { client: options.client } : {}),
      ...(options.maxReconnectAttempts !== undefined ? { maxReconnectAttempts: options.maxReconnectAttempts } : {}),
    }
  }

  private update(change: Partial<ConnectionSnapshot>): void {
    const next = { ...this.get(), ...change }
    if (change.link) this.noticeTrying(this.get().link, change.link, next)
    this.set(next)
  }

  private noticeTrying(old: LinkState, link: LinkState, next: ConnectionSnapshot): void {
    const trying = link.phase === 'connecting' || link.phase === 'reconnecting'
    const wasTrying = old.phase === 'connecting' || old.phase === 'reconnecting'
    if (trying && wasTrying) return
    clearTimeout(this.tryingTimer)
    this.tryingTimer = undefined
    next.isTryingNoticeably = false
    if (!trying) return
    this.tryingTimer = setTimeout(() => {
      const phase = this.get().link.phase
      if (phase === 'connecting' || phase === 'reconnecting') this.set({ ...this.get(), isTryingNoticeably: true })
    }, this.options.tryingNoticeDelayMs)
  }

  /** Connects with `connector`, replacing any earlier connection. */
  async connect(connector: GatewayConnector): Promise<void> {
    const gen = ++this.generation
    await this.discardClient()
    if (gen !== this.generation) throw new CancelledError()
    this.connector = connector
    this.update({ link: { phase: 'connecting' } })
    try {
      const ready = await this.establish(gen)
      await this.chats.restore(ready, this.client, gen)
      if (gen !== this.generation) throw new CancelledError()
      this.update({ link: { phase: 'connected' } })
    } catch (error) {
      if (gen !== this.generation) throw new CancelledError()
      await this.discardClient()
      this.connector = undefined
      this.update({ link: { phase: 'failed', message: describeError(error) } })
      throw error
    }
    this.refreshListsInBackground()
  }

  /** Closes the connection and forgets everything it read. */
  async disconnect(): Promise<void> {
    const gen = ++this.generation
    await this.discardClient()
    if (gen !== this.generation) return
    this.connector = undefined
    this.sessionListToken += 1
    this.sessionListLimits.clear()
    this.chats.reset()
    this.update({ ...initial })
  }

  /** Hides the sources Settings ▸ Session Sources hides, and reads the list again. */
  setSourceSettings(settings: SessionSourceSettings): void {
    this.sourceSettings = settings
    void this.refreshSessionList()
  }

  /** The connector's REST routes (settings panes, cron), while one is set; undefined without REST access. */
  get dashboardAPI(): DashboardAPI | undefined { return dashboardAPIFor(this.connector) }

  /** One call on the live socket (`plugins.manage`); throws `notConnected` without one. */
  call(method: string, params?: JSONValue): Promise<JSONValue> {
    return this.client ? this.client.call(method, params) : Promise.reject(new GatewayClientError('notConnected'))
  }

  /**
   * Shows lists kept from an earlier launch (`sessions/list-cache.ts`) before the first
   * connect: nothing once this connection has read a roster of its own.
   */
  restoreLists(cache: { profiles: readonly ProfileRow[]; sessions: Record<string, readonly SessionSummary[]>; limits: Record<string, number>; selectedProfile?: string }): void {
    if (this.client || this.get().bots.length > 0 || cache.profiles.length === 0) return
    const bots = Bot.roster(cache.profiles)
    const names = new Set(bots.map((bot) => bot.name))
    const sessions = Object.fromEntries(Object.entries(cache.sessions).filter(([name]) => names.has(name)))
    for (const [name, limit] of Object.entries(cache.limits)) if (names.has(name)) this.sessionListLimits.set(name, limit)
    const selected = cache.selectedProfile && names.has(cache.selectedProfile)
      ? cache.selectedProfile : (bots.find((bot) => bot.isDefault) ?? bots[0])?.name
    this.update({ bots, sessions, ...(selected ? { selectedProfile: selected } : {}) })
  }

  /** The `session.list` limit that settled for `profile`, for the list cache. */
  sessionListLimit(profile: string): number | undefined {
    return this.sessionListLimits.get(profile)
  }

  /** Shows `profile`'s sessions, reading them when they are not there yet. */
  selectProfile(profile: string | undefined): void {
    if (profile === this.get().selectedProfile) return
    this.update({ selectedProfile: profile, sessionListError: undefined })
    void this.refreshSessionList()
  }

  private async establish(gen: number): Promise<GatewayReady> {
    const connector = this.connector
    if (!connector) throw new CancelledError()
    const transport = await connector.makeTransport()
    if (gen !== this.generation) {
      await transport.close()
      throw new CancelledError()
    }
    const client = new GatewayClient(transport, this.options.client)
    client.subscribe((item) => {
      if (client !== this.client) return
      if (item.kind === 'event' && item.event.type === EventType.sessionsChanged) this.refreshListsInBackground()
      this.chats.handle(item)
      this.alerts.handle(item)
      if (item.kind === 'disconnected' && item.error && this.connector) {
        this.client = undefined
        this.startReconnect()
      }
    })
    this.client = client
    try {
      const ready = await client.connect()
      this.alerts.connected()
      return ready
    } catch (error) {
      if (this.client === client) this.client = undefined
      throw error
    }
  }

  private async discardClient(): Promise<void> {
    const client = this.client
    this.client = undefined
    await client?.close()
  }

  private startReconnect(): void {
    if (this.reconnecting) return
    this.reconnecting = true
    void this.reconnectLoop(this.generation).finally(() => { this.reconnecting = false })
  }

  private async reconnectLoop(gen: number): Promise<void> {
    let attempt = 0
    while (gen === this.generation && this.connector) {
      attempt += 1
      this.update({ link: { phase: 'reconnecting', attempt } })
      await sleep(this.options.backoff(attempt))
      if (gen !== this.generation) return
      try {
        const ready = await this.establish(gen)
        await this.chats.restore(ready, this.client, gen)
        if (gen !== this.generation) return
        this.update({ link: { phase: 'connected' } })
        this.refreshListsInBackground()
        return
      } catch (error) {
        if (gen !== this.generation) return
        await this.discardClient()
        const final = error instanceof DashboardError &&
          (error.kind === 'unauthenticated' || error.kind === 'invalidCredentials')
        const max = this.options.maxReconnectAttempts
        if (final || (max !== undefined && attempt >= max)) {
          this.update({ link: { phase: 'failed', message: describeError(error) } })
          return
        }
      }
    }
  }

  /** Reloads the roster, then the selected profile's sessions; a call during a refresh queues one more. */
  refreshListsInBackground(): void {
    if (!this.client) return
    if (this.listsRefresh) {
      this.listsRefreshQueued = true
      return
    }
    const gen = this.generation
    this.listsRefresh = (async () => {
      try { await this.refreshBots() } catch {}
      await this.refreshSessionList()
    })().finally(() => {
      if (gen !== this.generation) return
      this.listsRefresh = undefined
      if (this.listsRefreshQueued) {
        this.listsRefreshQueued = false
        this.refreshListsInBackground()
      }
    })
  }

  /** Waits for the refresh in flight, if any (tests, and the app's first paint). */
  async settled(): Promise<void> {
    while (this.listsRefresh) await this.listsRefresh
  }

  /** Reloads the bots from `profiles.list`. */
  async refreshBots(): Promise<void> {
    const client = this.client
    if (!client) return
    const gen = this.generation
    const result = await client.call(GatewayMethod.profilesList, {}) as { profiles?: ProfileRow[] }
    if (gen !== this.generation) return
    const bots = Bot.roster(result.profiles ?? [])
    const names = new Set(bots.map((bot) => bot.name))
    const sessions = Object.fromEntries(Object.entries(this.get().sessions).filter(([name]) => names.has(name)))
    let selectedProfile = this.get().selectedProfile
    if (!selectedProfile || !names.has(selectedProfile)) {
      selectedProfile = (bots.find((bot) => bot.isDefault) ?? bots[0])?.name
    }
    this.update({ bots, sessions, selectedProfile })
  }

  /**
   * Reads the selected profile's sessions. The server reads `max(2*limit, 200)` rows,
   * drops internal sources, then cuts to `limit` (`methods_session.py:570-571`), so a
   * short answer is either the end or a window crowded by internal rows: a doubled
   * prefix is read again until a short answer stops growing, and later reads start at
   * the limit that settled (HermesKit's `refreshSessionList`).
   */
  async refreshSessionList(): Promise<void> {
    const client = this.client
    const profile = this.get().selectedProfile
    if (!client || !profile) return
    const token = ++this.sessionListToken
    const gen = this.generation
    this.update({ sessionListLoading: true, sessionListError: undefined })
    try {
      let limit = this.sessionListLimits.get(profile) ?? 200
      let settledBefore = this.sessionListLimits.has(profile)
      let previousCount = -1
      for (;;) {
        const result = await client.call(GatewayMethod.sessionList, { limit, profile } as JSONValue) as
          { sessions?: SessionSummary[] }
        if (token !== this.sessionListToken || gen !== this.generation) return
        const rows = result.sessions ?? []
        if (rows.length < limit && (settledBefore || rows.length <= previousCount)) {
          this.sessionListLimits.set(profile, limit)
          const bot = this.get().bots.find((candidate) => candidate.name === profile)
          this.update({
            sessions: { ...this.get().sessions, [profile]: historyRows(rows, bot).filter((row) => showsSource(this.sourceSettings, row.source)) },
            sessionListLoading: false,
          })
          return
        }
        settledBefore = false
        previousCount = rows.length
        limit *= 2
      }
    } catch (error) {
      if (token !== this.sessionListToken || gen !== this.generation) return
      this.update({ sessionListLoading: false, sessionListError: describeError(error) })
    }
  }
}

export class CancelledError extends Error {
  constructor() {
    super('cancelled')
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
