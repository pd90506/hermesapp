import { Bot, botChatTitle, type SessionSummary } from '../bots.ts'
import { GatewayClientError, type GatewayClient, type GatewayReady, type Inbound } from '../client.ts'
import { ChatComposer } from '../composer/chat-composer.ts'
import { StrandedImages } from '../composer/attachments/stranded.ts'
import { describeError } from '../describe.ts'
import { Observable } from '../observable.ts'
import { RPCError, type JSONValue } from '../protocol/jsonrpc.ts'
import { GatewayMethod } from '../protocol/methods.ts'
import { ChatSession, type ChatHost, type ChatKind, type LatestHistory } from './chat-session.ts'
import { SessionMethod, newSessionSource } from './methods.ts'
import {
  createdSnapshot, eventKind, requestSessionID, storedKey,
  type LiveSessionSnapshot, type OpenRequestEntry, type ServerRequest, type SessionCreateResult,
  type SessionMessagesSource,
} from './types.ts'

/** A chat being opened, not on screen yet (HermesKit's `PendingChat`). */
export interface PendingChat {
  profile?: string
  kind: ChatKind
  /** The stored title, when the open knows one (a session row). */
  title?: string
}

/** What the chat pane paints from. Replaced whole on every change. */
export interface ChatsSnapshot {
  /** The chat on screen. */
  active?: ChatSession
  /** A chat being opened: the pane shows its placeholder. */
  opening?: PendingChat
  /** The last open that failed, until the next one starts. */
  openError?: string
  /** Server requests of sessions not on screen (the sidebar marks their rows). */
  otherRequests: readonly ServerRequest[]
  /** Each profile's New chat, while nothing in it is listed yet. */
  unsent: Readonly<Record<string, ChatSession>>
}

/** What the chats need from their connection (`GatewayConnection`). */
export interface ChatsHost {
  readonly client: GatewayClient | undefined
  readonly messagesSource: SessionMessagesSource | undefined
  /** Bumped on every connect and disconnect: a late answer from before is dropped. */
  readonly generation: number
  readonly bots: readonly Bot[]
  refreshLists(): void
}

export class BotChatError extends Error {
  constructor(readonly kind: 'registryUnavailable' | 'registryUnconfirmed' | 'notRegistered', readonly profile: string,
    readonly detail?: string) {
    super(kind === 'registryUnavailable'
      ? `Couldn't look up ${profile}'s Bot Chat (${detail}). No new chat was started; try again.`
      : kind === 'registryUnconfirmed'
        ? `Couldn't confirm ${profile}'s Bot Chat. No new chat was started; try again.`
        : `Couldn't save ${profile}'s new Bot Chat (${detail}). Try again.`)
  }
}

/** The bot has no Bot Chat any more: a restore has nothing to resume. */
export class BotChatGoneError extends Error {
  constructor() {
    super('The bot has no Bot Chat any more.')
  }
}

/** A newer open replaced this one, or the socket did. */
export class OpenSupersededError extends Error {
  constructor() {
    super('superseded')
  }
}

/**
 * 4001 session not found, 4007 no longer live / stored session not found, 4064 the
 * session's profile no longer exists: retrying cannot help (HermesKit's `sessionGoneCodes`).
 */
export const sessionGoneCodes: ReadonlySet<number> = new Set([4001, 4007, 4064])

export function isSessionGone(error: unknown): boolean {
  if (error instanceof RPCError) return sessionGoneCodes.has(error.code)
  return error instanceof BotChatGoneError
}

interface Resumed {
  snapshot: LiveSessionSnapshot
  prefetch?: Promise<LatestHistory>
}

interface Opened {
  chat: ChatSession
  openRequests: readonly OpenRequestEntry[]
  prefetch?: Promise<LatestHistory>
}

/**
 * The chats of one connection (HermesKit's `GatewayConnection` session parts, `+Bots`,
 * `+Live` and `+Revisit`):
 * - opens a Bot Chat by its exact title (§8.2), a session row, a New chat (source
 *   `desktop`);
 * - keeps the last `warmChatLimit` chats warm: they keep receiving their events, and
 *   going back to one shows it at once, then binds it to this socket again and re-reads
 *   its newest rows (`revisit`);
 * - after a reconnect re-binds the chat on screen (§7): a reattach and replay on the same
 *   backend epoch, else a resume of its stored key (`session_key`), a Bot Chat looked up
 *   by its name again;
 * - a reclaimed runtime (`session.reclaimed`) resumes on the chat's next action.
 */
export class ChatManager extends Observable<ChatsSnapshot> {
  static readonly warmChatLimit = 6

  private warmChats: ChatSession[] = []
  private readonly composers = new Map<ChatSession, ChatComposer>()
  /** Runtime id serving each `profile/stored` key on this socket. */
  private readonly liveRuntimeIDs = new Map<string, string>()
  private readonly botChatOpens = new Map<string, Promise<Opened>>()
  private selectionToken = 0
  private openingToken = 0
  private committedEpoch?: string
  private readonly chatHost: ChatHost
  /** E: images failed sends left queued, kept across reopening a chat and reconnects (§10.3). */
  readonly strandedImages = new StrandedImages()

  constructor(private readonly host: ChatsHost) {
    super({ otherRequests: [], unsent: {} })
    const manager = this
    this.chatHost = {
      get client() { return manager.host.client },
      get messagesSource() { return manager.host.messagesSource },
      revive: (chat) => this.revive(chat),
      track: (chat) => this.track(chat),
      restoreText: (chat, text) => this.composer(chat).restoreText(text),
      strandedImages: this.strandedImages,
    }
  }

  get active(): ChatSession | undefined {
    return this.get().active
  }

  /** The chats kept warm, the one on screen first. */
  get warm(): readonly ChatSession[] {
    return this.warmChats
  }

  private update(change: Partial<ChatsSnapshot>): void {
    this.set({ ...this.get(), ...change })
  }

  // MARK: Composers

  /** The chat's composer: it lives with the chat while the chat is warm. */
  composer(chat: ChatSession): ChatComposer {
    let composer = this.composers.get(chat)
    if (!composer) {
      composer = new ChatComposer(chat, this.strandedImages)
      this.composers.set(chat, composer)
    }
    return composer
  }

  // MARK: Opening

  /** Opens a session row of `profile`'s list. */
  async openSession(profile: string, summary: SessionSummary): Promise<ChatSession> {
    const token = this.beginSelection()
    const current = this.active
    if (current && current.profile === profile && current.kind === 'sideChat' && current.storedSessionID === summary.id) {
      return this.keepShowing(current)
    }
    const client = this.requireClient()
    const warm = this.warmChats.find((chat) => chat.profile === profile && chat.kind === 'sideChat' &&
      chat.storedSessionID === summary.id)
    if (warm) return this.revisit(warm, client)
    const title = summary.title ?? undefined
    return this.opening({ profile, kind: 'sideChat', ...(title ? { title } : {}) }, token, async () => {
      const resumed = await this.resume(summary.id, profile, client)
      const chat = new ChatSession(resumed.snapshot, {
        storedSessionID: summary.id, profile, kind: 'sideChat', host: this.chatHost, ...(title ? { title } : {}),
      })
      return { chat, openRequests: resumed.snapshot.open_requests ?? [], ...(resumed.prefetch ? { prefetch: resumed.prefetch } : {}) }
    }, client)
  }

  /**
   * Opens the bot's one permanent chat, creating it only when the profile confirmably
   * has none. Concurrent opens of one profile share one lookup. Throws `BotChatError`
   * when the registry cannot be read or confirmed: retry, never create.
   */
  async openBotChat(profile: string): Promise<ChatSession> {
    const token = this.beginSelection()
    const current = this.active
    if (current && current.kind === 'botChat' && current.profile === profile) return this.keepShowing(current)
    const client = this.requireClient()
    const warm = this.warmChats.find((chat) => chat.kind === 'botChat' && chat.profile === profile)
    if (warm) return this.revisit(warm, client)
    return this.opening({ profile, kind: 'botChat', title: botChatTitle }, token, async () => {
      let task = this.botChatOpens.get(profile)
      if (!task) {
        task = this.resolveBotChat(profile, client)
        this.botChatOpens.set(profile, task)
        void task.catch(() => {}).finally(() => { if (this.botChatOpens.get(profile) === task) this.botChatOpens.delete(profile) })
      }
      const opened = await task
      this.host.refreshLists()
      return opened
    }, client)
  }

  /**
   * Starts a chat with a bot: a plain, visible, untitled session on its profile. The
   * profile's last New chat, while nothing was sent in it, comes back instead, with its
   * draft. One whose runtime was reclaimed is replaced, its draft carried over.
   */
  async newChat(profile: string): Promise<ChatSession> {
    const token = this.beginSelection()
    const client = this.requireClient()
    let carried: string | undefined
    const unsent = this.get().unsent[profile]
    if (unsent) {
      if (unsent.hasPrompted || unsent.transcript.items.length > 0) {
        this.setUnsent(profile, undefined)
      } else if (!unsent.isRuntimeGone) {
        return this.active === unsent ? this.keepShowing(unsent) : this.revisit(unsent, client)
      } else {
        carried = this.composer(unsent).draft
        this.setUnsent(profile, undefined)
        this.forget(unsent)
      }
    }
    const chat = await this.opening({ profile, kind: 'sideChat' }, token, async () => {
      const created = await client.call(SessionMethod.sessionCreate, { source: newSessionSource, profile }) as
        unknown as SessionCreateResult
      const chat = new ChatSession(createdSnapshot(created), {
        storedSessionID: created.stored_session_id, profile, kind: 'sideChat', host: this.chatHost,
      })
      if (carried) this.composer(chat).setDraft(carried)
      this.setUnsent(profile, chat)
      return { chat, openRequests: [] }
    }, client)
    this.host.refreshLists()
    return chat
  }

  /** The profile's New chat as a row above its sessions, while the list lacks its own row. */
  newChatRow(profile: string, listed: readonly SessionSummary[]): ChatSession | undefined {
    const chat = this.get().unsent[profile]
    if (!chat) return undefined
    if (!chat.hasPrompted && chat.transcript.items.length === 0) return chat
    return listed.some((row) => row.id === chat.storedSessionID) ? undefined : chat
  }

  /** Goes back to the profile's New chat, its row clicked. */
  async openNewChat(profile: string): Promise<ChatSession> {
    const chat = this.get().unsent[profile]
    if (!chat || (!chat.hasPrompted && chat.transcript.items.length === 0)) return this.newChat(profile)
    this.beginSelection()
    const client = this.requireClient()
    return this.active === chat ? this.keepShowing(chat) : this.revisit(chat, client)
  }

  private setUnsent(profile: string, chat: ChatSession | undefined): void {
    const unsent = { ...this.get().unsent }
    if (chat) unsent[profile] = chat
    else delete unsent[profile]
    this.update({ unsent })
  }

  private requireClient(): GatewayClient {
    const client = this.host.client
    if (!client) throw new GatewayClientError('notConnected')
    return client
  }

  private beginSelection(): number {
    this.selectionToken += 1
    if (this.get().openError !== undefined) {
      const { openError: _, ...rest } = this.get()
      this.set(rest)
    }
    return this.selectionToken
  }

  /** The user picked the chat already on screen: it stays, and an open in flight no longer hides it. */
  private keepShowing(chat: ChatSession): ChatSession {
    if (this.get().opening) {
      const { opening: _, ...rest } = this.get()
      this.set(rest)
    }
    return chat
  }

  /** Shows `pending` while `open` runs, then the chat, unless a newer open started meanwhile. */
  private async opening(pending: PendingChat, token: number, open: () => Promise<Opened>, client: GatewayClient): Promise<ChatSession> {
    this.openingToken = token
    this.update({ opening: pending })
    const gen = this.host.generation
    try {
      const opened = await open()
      if (gen !== this.host.generation || client !== this.host.client) throw new OpenSupersededError()
      this.show(opened, token, client)
      return opened.chat
    } catch (error) {
      if (this.openingToken === token && token === this.selectionToken && !(error instanceof OpenSupersededError)) {
        this.update({ openError: describeError(error) })
      }
      throw error
    } finally {
      if (this.openingToken === token && this.get().opening) {
        const { opening: _, ...rest } = this.get()
        this.set(rest)
      }
    }
  }

  /** Activates an opened chat unless a newer open started meanwhile, then re-delivers its requests. */
  private show(opened: Opened, token: number, client: GatewayClient): void {
    this.track(opened.chat)
    if (token === this.selectionToken && this.active !== opened.chat) this.activate(opened.chat)
    // On screen first; the stored transcript fills in as its newest page arrives.
    void opened.chat.loadHistory(opened.prefetch)
    client.redeliver(opened.openRequests)
  }

  private activate(chat: ChatSession): void {
    this.warmChats = [chat, ...this.warmChats.filter((other) => other !== chat)]
    const dropped = this.warmChats.slice(ChatManager.warmChatLimit)
    this.warmChats = this.warmChats.slice(0, ChatManager.warmChatLimit)
    const unsent = new Set(Object.values(this.get().unsent))
    for (const old of dropped) {
      if (unsent.has(old)) continue
      this.composers.delete(old)
      old.cancelRereadRetry()
    }
    this.track(chat)
    // Requests already parked for this session move into its transcript.
    const mine = this.get().otherRequests.filter((request) => requestSessionID(request) === chat.sessionID)
    const { opening: _, ...rest } = this.get()
    this.set({ ...rest, active: chat, otherRequests: this.get().otherRequests.filter((request) => !mine.includes(request)) })
    for (const request of mine) chat.receive(request)
  }

  // MARK: Bot Chat

  private async resolveBotChat(profile: string, client: GatewayClient): Promise<Opened> {
    // The roster names the chat's tip: its newest page is read alongside the lookup,
    // used only when the lookup names the same tip (§8.2: the lookup is the identity).
    const bot = this.host.bots.find((candidate) => candidate.name === profile)
    const canonical = bot?.profile.canonical_session
    const guess = canonical ? (canonical.resolved_id || canonical.id) : undefined
    const early = guess ? this.latestPageRead(guess, profile) : undefined
    let row: SessionSummary | undefined
    try {
      row = await this.lookUpBotChat(profile, client)
    } catch (error) {
      void early?.catch(() => {})
      throw error
    }
    if (row) {
      const target = row.resolved_id || row.id
      if (target !== guess) void early?.catch(() => {})
      return this.resumeBotChat(target, profile, client, target === guess ? early : undefined)
    }
    void early?.catch(() => {})
    // An empty answer is not proof: a backend mid-restart can list nothing.
    if (bot?.hasChat) throw new BotChatError('registryUnconfirmed', profile)
    const created = await client.call(SessionMethod.sessionCreate, {
      title: botChatTitle, source: newSessionSource, profile, hidden: true, follow_profile_config: true,
    }) as unknown as SessionCreateResult
    // Persists the row under the canonical title now, so a second open finds it.
    let titled: { pending?: boolean } | null
    try {
      titled = await client.call(SessionMethod.sessionTitle, { session_id: created.session_id, title: botChatTitle }) as
        { pending?: boolean } | null
    } catch (error) {
      if (error instanceof RPCError && /already in use/i.test(error.message)) {
        // Another writer created the Bot Chat since the lookup: adopt it.
        const winner = await this.lookUpBotChat(profile, client)
        if (!winner) throw new BotChatError('registryUnconfirmed', profile)
        return this.resumeBotChat(winner.resolved_id || winner.id, profile, client)
      }
      throw new BotChatError('notRegistered', profile, describeError(error))
    }
    if (titled?.pending === true) throw new BotChatError('notRegistered', profile, 'the gateway did not save the chat yet')
    const chat = new ChatSession(createdSnapshot(created), {
      storedSessionID: created.stored_session_id, title: botChatTitle, profile, kind: 'botChat', host: this.chatHost,
    })
    return { chat, openRequests: [] }
  }

  private async lookUpBotChat(profile: string, client: GatewayClient): Promise<SessionSummary | undefined> {
    try {
      return await this.findBotChat(profile, client)
    } catch (error) {
      throw new BotChatError('registryUnavailable', profile, describeError(error))
    }
  }

  /** The exact-title registry lookup on the bot's own profile; Bot Chats are born hidden. */
  private async findBotChat(profile: string, client: GatewayClient): Promise<SessionSummary | undefined> {
    const result = await client.call(GatewayMethod.sessionList, {
      limit: 200, include_hidden: true, title: botChatTitle, profile,
    }) as { sessions?: SessionSummary[] } | null
    return (result?.sessions ?? []).find((row) => Bot.isChatRow(row))
  }

  /** The stored id a restore of a Bot Chat resumes: the registry's current tip, looked up again. */
  private async botChatRestoreTarget(profile: string, client: GatewayClient): Promise<string> {
    const row = await this.findBotChat(profile, client)
    if (!row) throw new BotChatGoneError()
    return row.resolved_id || row.id
  }

  private async resumeBotChat(target: string, profile: string, client: GatewayClient,
    prefetch?: Promise<LatestHistory>): Promise<Opened> {
    const resumed = await this.resume(target, profile, client, prefetch)
    const chat = new ChatSession(resumed.snapshot, {
      storedSessionID: target, title: botChatTitle, profile, kind: 'botChat', host: this.chatHost,
    })
    return { chat, openRequests: resumed.snapshot.open_requests ?? [], ...(resumed.prefetch ? { prefetch: resumed.prefetch } : {}) }
  }

  // MARK: Resume

  /** A read of a stored transcript's newest page, started now. */
  private latestPageRead(key: string, profile: string | undefined): Promise<LatestHistory> | undefined {
    const source = this.host.messagesSource
    if (!source) return undefined
    const read = ChatSession.fetchLatest({ sessionID: key, limit: ChatSession.pageSize, ...(profile !== undefined ? { profile } : {}) }, source)
    read.catch(() => {})
    return read
  }

  /**
   * `session.resume` with a bounded ack, and the newest page read alongside it, as
   * Desktop opens chats. The page is kept only while the runtime is still hydrating
   * (no turn has run on it yet); otherwise it is read again after the ack.
   */
  private async resume(key: string, profile: string | undefined, client: GatewayClient,
    started?: Promise<LatestHistory>): Promise<Resumed> {
    const prefetch = started ?? this.latestPageRead(key, profile)
    const snapshot = await client.call(SessionMethod.sessionResume, {
      session_id: key, source: newSessionSource, omit_messages: true, defer_history: true,
      ...(profile !== undefined ? { profile } : {}),
    } as JSONValue) as unknown as LiveSessionSnapshot
    if (snapshot.hydrating === true && (storedKey(snapshot) ?? key) === key && prefetch) return { snapshot, prefetch }
    return { snapshot }
  }

  // MARK: Revisit

  /** The chats an event for runtime `sid` updates: the active one and warm ones on that runtime. */
  eventTargets(sid: string): ChatSession[] {
    const active = this.active
    if (sid === '') return active ? [active] : []
    const targets = this.warmChats.filter((chat) => chat.sessionID === sid)
    if (active && active.sessionID === sid && !targets.includes(active)) targets.push(active)
    return targets
  }

  /**
   * Shows `chat` now and reconciles it in the background: `session.activate` binds it to
   * this socket again, and a re-read brings in what was stored meanwhile. Its sends wait
   * for that (`ChatSession.settleIdentity`).
   */
  private revisit(chat: ChatSession, client: GatewayClient): ChatSession {
    this.activate(chat)
    if (chat.isReconciling && chat.reconcileClient === client) return chat
    chat.revisitToken += 1
    const mine = chat.revisitToken
    chat.isReconciling = true
    chat.reconcileClient = client
    const gen = this.host.generation
    chat.revisitTask = this.reconcile(chat, client, gen).finally(() => {
      if (chat.revisitToken !== mine) return
      chat.isReconciling = false
      chat.reconcileClient = undefined
    })
    return chat
  }

  private isCurrent(client: GatewayClient, gen: number): boolean {
    return gen === this.host.generation && client === this.host.client
  }

  private async reconcile(chat: ChatSession, client: GatewayClient, gen: number): Promise<void> {
    try {
      if (chat.kind === 'botChat' && chat.profile !== undefined) {
        const target = await this.botChatRestoreTarget(chat.profile, client)
        if (!this.isCurrent(client, gen)) return
        if (target !== chat.storedSessionID) {
          // Desktop retired or replaced the chat meanwhile: open the current one.
          await this.reopen(chat, target, client, gen)
          return
        }
      }
      if (chat.isRuntimeGone && chat.revival) {
        await chat.revival.catch(() => {})
        if (!chat.isRuntimeGone) return
      }
      if (chat.isRuntimeGone) {
        // Reclaimed: showing the chat is the action that resumes it.
        if (!this.isCurrent(client, gen)) return
        try {
          await this.reopen(chat, chat.storedSessionID ?? chat.sessionID, client, gen)
        } catch (error) {
          if (this.isCurrent(client, gen) && isSessionGone(error)) this.forget(chat)
        }
        return
      }
      const snapshot = await client.call(SessionMethod.sessionActivate, { session_id: chat.sessionID, omit_messages: true }) as
        unknown as LiveSessionSnapshot
      if (!this.isCurrent(client, gen)) return
      const key = storedKey(snapshot)
      if (key && chat.storedSessionID && key !== chat.storedSessionID) {
        // The runtime id answers for another stored session (a restarted backend), or
        // compression rotated the key: resume the key this chat was showing.
        await this.reopen(chat, chat.storedSessionID, client, gen)
        return
      }
      chat.update(snapshot)
      chat.retainRequests(new Set((snapshot.open_requests ?? []).map((entry) => entry.id)))
      chat.reconcileAfterRevisit(snapshot.running === true)
      client.redeliver(snapshot.open_requests ?? [])
    } catch (error) {
      if (!isSessionGone(error) || !this.isCurrent(client, gen)) return  // offline: the cached transcript stays
      if (error instanceof BotChatGoneError) {
        this.forget(chat)
        return
      }
      try {
        await this.reopen(chat, chat.storedSessionID ?? chat.sessionID, client, gen)
      } catch (reopenError) {
        if (this.isCurrent(client, gen) && isSessionGone(reopenError)) this.forget(chat)
      }
    }
  }

  /** Resumes `target` into `chat`, as a reconnect's cold restore does (§7). */
  private async reopen(chat: ChatSession, target: string, client: GatewayClient, gen: number): Promise<void> {
    const resumed = await this.resume(target, chat.profile, client)
    if (!this.isCurrent(client, gen)) return
    chat.reset(resumed.snapshot, target)
    void chat.loadHistory(resumed.prefetch)
    this.track(chat)
    client.redeliver(resumed.snapshot.open_requests ?? [])
  }

  /** Forgets a chat that can no longer be shown (gone, or deleted). */
  forget(chat: ChatSession): void {
    chat.cancelRereadRetry()
    this.warmChats = this.warmChats.filter((other) => other !== chat)
    this.composers.delete(chat)
    const unsent = Object.fromEntries(Object.entries(this.get().unsent).filter(([, other]) => other !== chat))
    if (this.active === chat) {
      const { active: _, ...rest } = this.get()
      this.set({ ...rest, unsent })
    } else {
      this.update({ unsent })
    }
  }

  // MARK: Reclaimed runtimes

  /**
   * Like Desktop (`gateway-event/lifecycle.ts:123-165`): forget the dead runtime and its
   * requests, keep the chat, resume it on its next action or when shown again. Only a
   * Bot Chat on screen is re-resolved at once, not after an `lru_evict`.
   */
  private sessionReclaimed(runtime: string, reason: string | undefined): void {
    for (const [key, id] of this.liveRuntimeIDs) if (id === runtime) this.liveRuntimeIDs.delete(key)
    this.update({ otherRequests: this.get().otherRequests.filter((request) => requestSessionID(request) !== runtime) })
    this.host.refreshLists()
    const chats = new Set([...this.warmChats, ...(this.active ? [this.active] : [])])
    for (const chat of chats) if (chat.sessionID === runtime && !chat.isRuntimeGone) chat.markRuntimeGone()
    const active = this.active
    if (active && active.sessionID === runtime && active.kind === 'botChat' && reason !== 'lru_evict') {
      void this.revive(active).catch(() => {})
    }
  }

  /**
   * Resumes a chat whose runtime was reclaimed, like a reconnect's cold restore. One
   * revival at a time per chat, and none while a reconnect or revisit is binding it.
   */
  async revive(chat: ChatSession): Promise<void> {
    await chat.settleIdentity()
    if (!chat.isRuntimeGone) return
    if (chat.revival) return chat.revival
    const client = this.requireClient()
    const gen = this.host.generation
    const task = this.coldRestore(chat, client, gen)
    chat.revival = task
    chat.identityGate = task.catch(() => {})
    try {
      await task
    } catch (error) {
      if (gen === this.host.generation && isSessionGone(error)) this.forget(chat)
      throw error
    } finally {
      if (chat.revival === task) chat.revival = undefined
    }
  }

  // MARK: Reconnect

  /**
   * Re-binds the chat on screen to a new socket, before the connection reports
   * `connected` (§7): a reattach and replay when the backend is the same (same
   * `replay_epoch`) and a `seq` is known, else a resume of its stored key. A chat the
   * server no longer has leaves the screen; other errors propagate and keep it for the
   * next attempt. The chat's actions wait for this.
   */
  async restore(ready: GatewayReady, client: GatewayClient | undefined, gen: number): Promise<void> {
    if (!client) throw new GatewayClientError('connectionClosed')
    this.strandedImages.flushInBackground(client)
    const chat = this.active
    if (!chat) {
      this.committedEpoch = ready.replay_epoch
      return
    }
    let release!: () => void
    chat.identityGate = new Promise<void>((resolve) => { release = resolve })
    try {
      await this.restoreActive(chat, ready, client, gen)
      this.committedEpoch = ready.replay_epoch
    } catch (error) {
      if (!isSessionGone(error)) throw error
      if (gen === this.host.generation) {
        this.committedEpoch = ready.replay_epoch
        this.forget(chat)
      }
    } finally {
      release()
    }
  }

  private async restoreActive(chat: ChatSession, ready: GatewayReady, client: GatewayClient, gen: number): Promise<void> {
    const lastSeq = chat.lastSeq
    if (!chat.isRuntimeGone && this.committedEpoch !== undefined && this.committedEpoch === ready.replay_epoch &&
        lastSeq !== undefined) {
      try {
        const result = await client.reattach(chat.sessionID, lastSeq)
        if (gen !== this.host.generation) throw new OpenSupersededError()
        if (result.isComplete) {
          chat.update(result.snapshot)
          const open = [...(result.replay.open_requests ?? []), ...(result.snapshot.open_requests ?? [])].map((entry) => entry.id)
          chat.retainRequests(new Set(open))
          return
        }
      } catch (error) {
        // 4001 not found / 4007 no longer live: the runtime is gone; resume it.
        if (!(error instanceof RPCError)) throw error
      }
    }
    await this.coldRestore(chat, client, gen)
  }

  /** Resumes `chat` from its stored key on `client` and rebuilds its transcript. */
  private async coldRestore(chat: ChatSession, client: GatewayClient, gen: number): Promise<void> {
    // A Bot Chat is found by its name again, never by the id it had before the outage.
    const target = chat.kind === 'botChat' && chat.profile !== undefined
      ? await this.botChatRestoreTarget(chat.profile, client)
      : chat.storedSessionID ?? chat.sessionID
    if (gen !== this.host.generation) throw new OpenSupersededError()
    const resumed = await this.resume(target, chat.profile, client)
    if (gen !== this.host.generation) throw new OpenSupersededError()
    chat.reset(resumed.snapshot, target)
    void chat.loadHistory(resumed.prefetch)
    this.track(chat)
    client.redeliver(resumed.snapshot.open_requests ?? [])
  }

  /** The socket closed and the connection forgets everything (`disconnect`). */
  reset(): void {
    for (const chat of new Set([...this.warmChats, ...Object.values(this.get().unsent), ...(this.active ? [this.active] : [])])) {
      chat.detach()
    }
    this.warmChats = []
    this.composers.clear()
    this.liveRuntimeIDs.clear()
    this.botChatOpens.clear()
    this.committedEpoch = undefined
    this.selectionToken += 1
    this.set({ otherRequests: [], unsent: {} })
  }

  // MARK: Inbound

  /** Routes what the socket delivers to the chats. */
  handle(item: Inbound): void {
    switch (item.kind) {
      case 'event': {
        const event = item.event
        const kind = eventKind(event)
        if (kind.kind === 'requestCancel') {
          const id = kind.cancel.id
          if (this.get().otherRequests.some((request) => request.id === id)) {
            this.update({ otherRequests: this.get().otherRequests.filter((request) => request.id !== id) })
          }
        } else if (kind.kind === 'sessionReclaimed') {
          this.sessionReclaimed(kind.reclaimed.session_id, kind.reclaimed.reason)
        }
        for (const chat of this.eventTargets(event.session_id ?? '')) {
          chat.apply(event)
          // A finished turn moved the bot's preview and the session rows.
          if (kind.kind === 'messageComplete' && chat.profile !== undefined) this.host.refreshLists()
        }
        return
      }
      case 'serverRequest': {
        const request = item.request
        const active = this.active
        if (active && requestSessionID(request) === active.sessionID) {
          active.receive(request)
        } else if (!this.get().otherRequests.some((other) => other.id === request.id)) {
          this.update({ otherRequests: [...this.get().otherRequests, request] })
        }
        return
      }
      case 'disconnected':
        return
    }
  }

  // MARK: Live runtime ids

  private track(chat: ChatSession): void {
    const stored = chat.storedSessionID
    if (!stored) return
    this.liveRuntimeIDs.set(`${chat.profile ?? ''}/${stored}`, chat.sessionID)
  }
}
