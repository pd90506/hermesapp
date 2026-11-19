import { Bot, type ProfileRow, type SessionSummary } from '../bots.ts'
import type { ConnectionSnapshot, GatewayConnection } from '../connection.ts'
import { describeError } from '../describe.ts'
import { Observable } from '../observable.ts'
import { GatewayMethod } from '../protocol/methods.ts'
import { SessionReadMarks, activityCacheKey, listDate, readRowActivity, sortByListDate, type SessionRowActivity } from './activity.ts'
import { avatarDataURL, hasAvatar } from './avatar.ts'
import { sessionDateGroups, type CalendarOptions, type SessionDateGroup } from './date-groups.ts'
import { SessionActionError, SessionActions } from './manage.ts'
import { SessionPins } from './pins.ts'
import { markRead, readWatermarks, type SessionsREST } from './rest.ts'
import { searchResults, searchSessions, type SessionSearchResult } from './search.ts'
import type { ChatStatus, LiveChatStatus, WaitingChat } from './status.ts'

/** What the sidebar has selected: a profile's Bot Chat, or one of its sessions. */
export type SidebarSelection = { kind: 'bot'; profile: string } | { kind: 'session'; profile: string; id: string }

export interface SessionSearchState {
  /** The query `results` answer, trimmed; empty when nothing was searched. */
  query: string
  results: SessionSearchResult[]
  searching: boolean
  error?: string
  /** False when the sign-in can't read the dashboard, so nothing can be searched. */
  available: boolean
}

export interface SidebarSnapshot {
  pins: SessionPins
  readMarks: SessionReadMarks
  /** What each row read last, by `profile/id`, with the cache key it was read at. */
  activity: Readonly<Record<string, { key: string; activity: SessionRowActivity }>>
  /** Avatar images (data URLs) by profile name. */
  avatars: Readonly<Record<string, string>>
  search: SessionSearchState
  selection?: SidebarSelection
  /** The last failed row action, shown over the tabs until dismissed. */
  actionError?: string
  /** Bumped when the live chats' status changes (package A). */
  liveRevision: number
}

/** What the sidebar keeps across launches (`talaria.sidebar`), per server. */
export interface SidebarStore {
  load(): Promise<unknown>
  save(value: unknown): void
}

export interface SessionSidebarOptions {
  connection: GatewayConnection
  /** The dashboard REST of the connected server, when its sign-in can read it. */
  rest: () => SessionsREST | undefined
  /** The connected server's key (pins and kept lists are per server). */
  serverKey: () => string | undefined
  store?: SidebarStore
  now?: () => number
  /** How often the lists are re-read while connected (Desktop re-reads the roster every 5 s; the Mac every 15). */
  refreshIntervalMs?: number
}

interface Kept {
  pins?: string[]
  readMarks?: unknown
  /** Server key → the lists as read last (HermesKit's `SessionListCache`). */
  lists?: Record<string, KeptLists>
}

interface KeptLists {
  profiles: ProfileRow[]
  sessions: Record<string, SessionSummary[]>
  limits: Record<string, number>
  activity: Record<string, { key: string; activity: SessionRowActivity }>
  avatars: Record<string, string>
  selectedProfile?: string
}

const idleLive: LiveChatStatus = {
  status: () => 'idle',
  botChatStatus: () => 'idle',
  waitingChats: () => [],
  subscribe: () => () => {},
}

/** Rows read at once (HermesKit's `rowActivityReadLimit`). */
const rowReadLimit = 4

/**
 * Everything the sidebar knows beyond the connection's lists (HermesKit's
 * `GatewayConnection+Bots` row reads, `+ReadSync`, `+Avatars`, `+Manage`,
 * `SessionSearch`, `SessionListCache`): pins, each row's activity and unread state,
 * Hermes's shared read watermark, avatars, search, and the row actions.
 */
export class SessionSidebar extends Observable<SidebarSnapshot> {
  private readonly connection: GatewayConnection
  private readonly options: SessionSidebarOptions
  private readonly now: () => number
  private live: LiveChatStatus = idleLive
  private liveUnsubscribe?: () => void
  /** Rows read in flight, by cache key. */
  private readonly reading = new Set<string>()
  /** Hermes's watermark per `profile/id`, Unix seconds. */
  private readonly serverMarks = new Map<string, number>()
  /** Pushes tried on this connection, `profile/id` → the reply pushed. */
  private readonly pushed = new Map<string, number>()
  private pushing = false
  private readonly avatarLoads = new Set<string>()
  private lastLists?: ConnectionSnapshot['sessions']
  private lastBots?: ConnectionSnapshot['bots']
  private lastPhase?: string
  private searchToken = 0
  private refreshTimer?: unknown
  private saveTimer?: unknown
  private kept: Kept = {}
  private loaded = false

  constructor(options: SessionSidebarOptions) {
    super({
      pins: new SessionPins(), readMarks: new SessionReadMarks(), activity: {}, avatars: {},
      search: { query: '', results: [], searching: false, available: true }, liveRevision: 0,
    })
    this.options = options
    this.connection = options.connection
    this.now = options.now ?? (() => Date.now())
    this.connection.subscribe(() => this.connectionChanged())
  }

  private update(change: Partial<SidebarSnapshot>): void {
    this.set({ ...this.get(), ...change })
  }

  // MARK: Keeping

  /** Reads what was kept and shows the server's kept lists before the first connect. */
  async load(): Promise<void> {
    const value = (await this.options.store?.load().catch(() => undefined)) as Kept | undefined
    this.kept = value && typeof value === 'object' ? value : {}
    this.loaded = true
    const readMarks = SessionReadMarks.fromJSON(this.kept.readMarks).start(this.now())
    this.update({ pins: new SessionPins(this.kept.pins ?? []), readMarks })
    this.restore()
  }

  /** The server's kept lists, shown while it connects (the user, 2026-11-12: no "Loading…" for seconds). */
  restore(): void {
    const server = this.options.serverKey()
    const lists = server ? this.kept.lists?.[server] : undefined
    if (!lists) return
    this.connection.restoreLists(lists)
    const known = new Set(lists.profiles.filter((row) => row.has_avatar).map((row) => row.name))
    this.update({
      activity: { ...lists.activity, ...this.get().activity },
      avatars: Object.fromEntries(Object.entries(lists.avatars).filter(([name]) => known.has(name))),
    })
  }

  private scheduleSave(): void {
    if (!this.loaded || !this.options.store) return
    clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.save(), 500)
  }

  private save(): void {
    const snapshot = this.get()
    const connection = this.connection.get()
    const server = this.options.serverKey()
    const lists = { ...this.kept.lists }
    if (server && connection.bots.length > 0) {
      const profiles = connection.bots.map((bot) => bot.profile)
      const sessions = Object.fromEntries(Object.entries(connection.sessions).map(([name, rows]) => [name, [...rows]]))
      const limits: Record<string, number> = {}
      for (const name of Object.keys(sessions)) {
        const limit = this.connection.sessionListLimit(name)
        if (limit !== undefined) limits[name] = limit
      }
      const activity: KeptLists['activity'] = {}
      for (const [name, rows] of Object.entries(sessions)) {
        for (const row of rows) {
          const read = snapshot.activity[`${name}/${row.id}`]
          if (read) activity[`${name}/${row.id}`] = read
        }
      }
      lists[server] = {
        profiles, sessions, limits, activity, avatars: { ...snapshot.avatars },
        ...(connection.selectedProfile ? { selectedProfile: connection.selectedProfile } : {}),
      }
    }
    this.kept = { pins: snapshot.pins.toJSON(), readMarks: snapshot.readMarks.toJSON(), lists }
    this.options.store?.save(this.kept)
  }

  /** A forgotten server's pins and lists go with it. */
  forgetServer(server: string): void {
    const lists = { ...this.kept.lists }
    delete lists[server]
    this.kept = { ...this.kept, lists }
    this.update({ pins: this.get().pins.forgetServer(server) })
    this.scheduleSave()
  }

  // MARK: Live chats (package A)

  /** The chat core's view of its live chats: status dots, "waiting", what is on screen. */
  setLiveStatus(live: LiveChatStatus | undefined): void {
    this.liveUnsubscribe?.()
    this.live = live ?? idleLive
    this.liveUnsubscribe = this.live.subscribe(() => this.update({ liveRevision: this.get().liveRevision + 1 }))
    this.update({ liveRevision: this.get().liveRevision + 1 })
  }

  status(profile: string, id: string): ChatStatus {
    return this.live.status(profile, id)
  }

  botChatStatus(profile: string): ChatStatus {
    return this.live.botChatStatus(profile)
  }

  waitingChats(): WaitingChat[] {
    return this.live.waitingChats()
  }

  // MARK: Rows

  /** The row's activity, as read last. */
  activity(profile: string, id: string): SessionRowActivity | undefined {
    return this.get().activity[`${profile}/${id}`]?.activity
  }

  /** The row's date in the list: the user's last prompt (one just sent here counts at once), else its newest message. */
  listDate(profile: string, id: string): number | undefined {
    const read = listDate(this.activity(profile, id))
    const local = this.live.lastPromptAt?.(profile, id)
    if (local === undefined) return read
    return Math.max(local, read ?? local)
  }

  /** `rows` (server order) in the list's order: the user's last prompt first (the user, 2026-10-29). */
  ordered(profile: string, rows: readonly SessionSummary[]): SessionSummary[] {
    return sortByListDate(rows, rows.map((row) => this.listDate(profile, row.id)))
  }

  /** Pinned rows above, the rest in date groups (pinned rows aren't dated). */
  sections(server: string, profile: string, rows: readonly SessionSummary[], options: CalendarOptions = {}):
    { pinned: SessionSummary[]; groups: SessionDateGroup<SessionSummary>[] } {
    const { pinned, others } = this.get().pins.split(this.ordered(profile, rows), server, profile)
    const groups = sessionDateGroups(others, others.map((row) => this.listDate(profile, row.id)), this.now(), options)
    return { pinned, groups }
  }

  /** A reply came that wasn't seen here. Never for the selected row. */
  isUnread(profile: string, id: string): boolean {
    if (this.isOnScreen(profile, id)) return false
    return this.get().readMarks.isUnread(profile, id, this.activity(profile, id)?.newestReply)
  }

  private isOnScreen(profile: string, id: string): boolean {
    const selection = this.get().selection
    return selection?.kind === 'session' && selection.profile === profile && selection.id === id
  }

  /**
   * Selects a row. Until the chat core opens chats (package A), the selected session
   * counts as on screen: it is seen, and its newest reply is marked read on the server.
   */
  select(selection: SidebarSelection | undefined): void {
    const old = this.get().selection
    this.update({ selection })
    for (const each of [old, selection]) {
      if (each?.kind === 'session') this.markSeen(each.profile, each.id, this.now())
    }
  }

  private markSeen(profile: string, id: string, time: number): void {
    const marks = this.get().readMarks.markSeen(profile, id, time)
    if (marks === this.get().readMarks) return
    this.update({ readMarks: marks })
    this.scheduleSave()
    const row = this.connection.get().sessions[profile]?.find((candidate) => candidate.id === id)
    if (row) void this.pushReadMarks(profile, [row])
  }

  // MARK: Pins

  isPinned(server: string, profile: string, id: string): boolean {
    return this.get().pins.isPinned(server, profile, id)
  }

  setPinned(pinned: boolean, server: string, profile: string, id: string): void {
    this.update({ pins: this.get().pins.setPinned(pinned, server, profile, id) })
    this.scheduleSave()
  }

  // MARK: Actions

  private bot(profile: string): Bot | undefined {
    return this.connection.get().bots.find((bot) => bot.name === profile)
  }

  private call = (method: string, params: Parameters<GatewayConnection['call']>[1]) => this.connection.call(method, params)

  /** Runs a row action; a failure shows in the banner over the tabs. */
  private async act<T>(action: () => Promise<T>): Promise<T | undefined> {
    try {
      const result = await action()
      return result
    } catch (error) {
      this.update({ actionError: error instanceof SessionActionError ? error.message : describeError(error) })
      return undefined
    }
  }

  dismissActionError(): void {
    this.update({ actionError: undefined })
  }

  /** Renames a chat open here; `runtimeID` from the chat core. */
  async rename(profile: string, row: SessionSummary, title: string, runtimeID?: string): Promise<void> {
    const renamed = await this.act(() => SessionActions.rename(this.call, row, this.bot(profile), title, runtimeID))
    if (renamed !== undefined) this.connection.refreshListsInBackground()
  }

  async archive(profile: string, row: SessionSummary): Promise<void> {
    if (await this.act(async () => { await SessionActions.archive(this.call, row, profile, this.bot(profile)); return true })) {
      if (this.isOnScreen(profile, row.id)) this.update({ selection: { kind: 'bot', profile } })
      this.connection.refreshListsInBackground()
    }
  }

  async delete(profile: string, row: SessionSummary): Promise<void> {
    if (await this.act(async () => { await SessionActions.delete(this.call, row, profile, this.bot(profile)); return true })) {
      if (this.isOnScreen(profile, row.id)) this.update({ selection: { kind: 'bot', profile } })
      this.connection.refreshListsInBackground()
    }
  }

  /** Forks the row and selects the copy once it is listed. */
  async fork(profile: string, row: SessionSummary): Promise<void> {
    const id = await this.act(() => SessionActions.fork(this.call, row, profile, this.bot(profile)))
    if (!id) return
    await this.connection.refreshSessionList()
    this.select({ kind: 'session', profile, id })
  }

  // MARK: Avatars

  /** Stores `dataURL` (PNG, JPEG or WebP, at most 2 MB) as the profile's avatar and shows it at once. */
  async setAvatar(profile: string, dataURL: string): Promise<void> {
    await this.connection.call(GatewayMethod.profilesSetAsset, { name: profile, asset: 'avatar', data: dataURL })
    this.update({ avatars: { ...this.get().avatars, [profile]: dataURL } })
    await this.connection.refreshBots().catch(() => {})
    this.scheduleSave()
  }

  async removeAvatar(profile: string): Promise<void> {
    await this.connection.call(GatewayMethod.profilesSetAsset, { name: profile, asset: 'avatar', clear: true })
    const avatars = { ...this.get().avatars }
    delete avatars[profile]
    this.update({ avatars })
    await this.connection.refreshBots().catch(() => {})
    this.scheduleSave()
  }

  /** Reads the avatars not loaded yet; forgets those the roster no longer has (Desktop's `pullServerAvatars`). */
  private loadAvatars(bots: readonly Bot[]): void {
    const withAvatar = new Set(bots.filter(hasAvatar).map((bot) => bot.name))
    const avatars = Object.fromEntries(Object.entries(this.get().avatars).filter(([name]) => withAvatar.has(name)))
    if (Object.keys(avatars).length !== Object.keys(this.get().avatars).length) this.update({ avatars })
    if (this.connection.get().link.phase !== 'connected') return
    for (const name of withAvatar) {
      if (this.avatarLoads.has(name)) continue
      this.avatarLoads.add(name)
      void this.connection.call(GatewayMethod.profilesGetAsset, { name, asset: 'avatar' }).then((result) => {
        const answer = result as { found?: boolean; data?: string | null }
        const url = answer.found ? avatarDataURL(answer.data) : undefined
        if (!url || !this.connection.get().bots.some((bot) => bot.name === name && hasAvatar(bot))) return
        this.update({ avatars: { ...this.get().avatars, [name]: url } })
        this.scheduleSave()
      }, () => { this.avatarLoads.delete(name) })
    }
  }

  // MARK: Search

  /**
   * Searches the selected profile's sessions; an empty query clears the results. A later
   * call supersedes one still running. Only the sources the list shows are searched.
   */
  async search(query: string): Promise<void> {
    const trimmed = query.trim()
    const profile = this.connection.get().selectedProfile
    const token = ++this.searchToken
    if (!trimmed || !profile) {
      this.update({ search: { query: '', results: [], searching: false, available: true } })
      return
    }
    const rest = this.options.rest()
    if (!rest) {
      this.update({ search: { ...this.get().search, searching: false, available: false } })
      return
    }
    this.update({ search: { ...this.get().search, searching: true, available: true } })
    try {
      const hits = await searchSessions(rest, trimmed, profile)
      if (token !== this.searchToken || this.connection.get().selectedProfile !== profile) return
      const listed = this.connection.get().sessions[profile] ?? []
      this.update({ search: { query: trimmed, results: searchResults(hits, listed, this.bot(profile)), searching: false, available: true } })
    } catch (error) {
      if (token !== this.searchToken) return
      this.update({ search: { query: trimmed, results: [], searching: false, available: true, error: describeError(error) } })
    }
  }

  // MARK: Following the connection

  private connectionChanged(): void {
    const snapshot = this.connection.get()
    const phase = snapshot.link.phase
    if (phase !== this.lastPhase) {
      const wasConnected = this.lastPhase === 'connected'
      this.lastPhase = phase
      if (phase === 'connected') {
        this.startRefreshing()
        this.loadAvatars(snapshot.bots)
      } else if (wasConnected) {
        clearInterval(this.refreshTimer)
        this.refreshTimer = undefined
        // A new connection reads its watermark and avatars again.
        this.serverMarks.clear()
        this.pushed.clear()
        this.avatarLoads.clear()
      }
      if (phase === 'disconnected' && snapshot.bots.length === 0) {
        this.update({ activity: {}, avatars: {}, selection: undefined, search: { query: '', results: [], searching: false, available: true } })
      }
    }
    if (snapshot.bots !== this.lastBots) {
      this.lastBots = snapshot.bots
      this.loadAvatars(snapshot.bots)
      this.scheduleSave()
    }
    if (snapshot.sessions !== this.lastLists) {
      const old = this.lastLists ?? {}
      this.lastLists = snapshot.sessions
      for (const [profile, rows] of Object.entries(snapshot.sessions)) {
        if (rows !== old[profile] && phase === 'connected') void this.readRows(profile, rows)
      }
      this.scheduleSave()
    }
  }

  private startRefreshing(): void {
    clearInterval(this.refreshTimer)
    const interval = this.options.refreshIntervalMs ?? 15_000
    if (interval <= 0) return
    this.refreshTimer = setInterval(() => this.connection.refreshListsInBackground(), interval)
  }

  /** Stops the refresh timer (tests, a closed window). */
  dispose(): void {
    clearInterval(this.refreshTimer)
    clearTimeout(this.saveTimer)
    this.liveUnsubscribe?.()
  }

  /**
   * Reads the activity of every row not read since its stored message count changed, top
   * rows first, a few at a time; the watermark is pulled first and pushed after. A row
   * keeps what it read last until the new read lands, so a message arriving doesn't
   * blank its date or its unread dot in between.
   */
  async readRows(profile: string, rows: readonly SessionSummary[]): Promise<void> {
    const rest = this.options.rest()
    if (!rest) return
    await this.pullReadMarks(rest, profile)
    const pending = rows.flatMap((row) => {
      const cacheKey = activityCacheKey(profile, row)
      const key = cacheKey ?? `${profile}/${row.id}/?`
      const cached = cacheKey !== undefined && this.get().activity[`${profile}/${row.id}`]?.key === key
      return cached || this.reading.has(key) ? [] : [{ key, row }]
    })
    for (const { key } of pending) this.reading.add(key)
    const worker = async () => {
      for (let next = pending.shift(); next; next = pending.shift()) {
        const { key, row } = next
        try {
          const activity = await readRowActivity(rest, row.resolved_id ?? row.id, profile)
          this.update({ activity: { ...this.get().activity, [`${profile}/${row.id}`]: { key, activity } } })
          if (this.isOnScreen(profile, row.id) && activity.newestReply !== undefined) {
            this.update({ readMarks: this.get().readMarks.markSeen(profile, row.id, activity.newestReply) })
          }
        } catch {
          // Kept as read last; the next refresh tries again.
        } finally {
          this.reading.delete(key)
        }
      }
    }
    await Promise.all(Array.from({ length: Math.min(rowReadLimit, pending.length) }, worker))
    this.scheduleSave()
    await this.pushReadMarks(profile, rows)
  }

  private async pullReadMarks(rest: SessionsREST, profile: string): Promise<void> {
    let marks: Map<string, number>
    try {
      marks = await readWatermarks(rest, profile)
    } catch {
      return
    }
    let readMarks = this.get().readMarks
    for (const [id, read] of marks) {
      this.serverMarks.set(`${profile}/${id}`, read)
      if (read > 0) readMarks = readMarks.markSeen(profile, id, read * 1000)
    }
    if (readMarks !== this.get().readMarks) {
      this.update({ readMarks })
      this.scheduleSave()
    }
  }

  /**
   * Marks read on the server the rows whose newest reply was seen here but is past the
   * watermark, one at a time, each once per connection.
   */
  private async pushReadMarks(profile: string, rows: readonly SessionSummary[]): Promise<void> {
    const rest = this.options.rest()
    if (!rest || this.pushing) return
    this.pushing = true
    try {
      for (const row of rows) {
        const key = `${profile}/${row.id}`
        const reply = this.activity(profile, row.id)?.newestReply
        const server = this.serverMarks.get(key)
        if (reply === undefined || server === undefined || server * 1000 >= reply) continue
        const seen = this.isOnScreen(profile, row.id) || (this.get().readMarks.seenThrough(profile, row.id) ?? -Infinity) >= reply
        if (!seen || this.pushed.get(key) === reply) continue
        this.pushed.set(key, reply)
        try {
          await markRead(rest, row.id, profile)
          this.serverMarks.set(key, reply / 1000)
        } catch {
          // Tried once on this connection.
        }
      }
    } finally {
      this.pushing = false
    }
  }
}
