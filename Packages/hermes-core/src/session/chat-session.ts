import { GatewayClientError, type GatewayClient, type GatewayEvent } from '../client.ts'
import { SessionUsageTracker } from '../composer/context/session-usage.ts'
import { describeError } from '../describe.ts'
import { Observable } from '../observable.ts'
import type { JSONValue } from '../protocol/jsonrpc.ts'
import { compressionMessage, type SessionCompressResult } from '../composer/queue/compression.ts'
import { blockKind, transcriptBlocks, type TranscriptBlock } from './blocks.ts'
import { compressionDisplayKind, isQueuedPrompt, type TranscriptItem } from './items.ts'
import { SessionMethod, promptSubmitTimeoutMs, sessionCompressTimeoutMs } from './methods.ts'
import { userDisplayText } from './stored-projection.ts'
import { StreamedTextQueue } from './streamed-text-queue.ts'
import { Transcript, type HistoryPaging, type Waiting } from './transcript.ts'
import {
  eventKind, storedKey,
  type ApprovalChoice, type LiveSessionSnapshot, type ServerRequest, type SessionLiveInfo,
  type SessionMessagesPage, type SessionMessagesQuery, type SessionMessagesSource, type StoredMessage,
} from './types.ts'

/** Loading state of a chat's stored transcript (HermesKit's `HistoryLoad`). */
export type HistoryLoad =
  | { phase: 'idle' }
  | { phase: 'loadingLatest' }
  | { phase: 'loadingOlder' }
  /** The newest page could not be read; the chat still works (`retryHistory`). */
  | { phase: 'latestFailed'; message: string }
  /** An older page could not be read; `retryHistory` or scrolling up retries. */
  | { phase: 'olderFailed'; message: string }
  /** This connection cannot read stored transcripts at all. */
  | { phase: 'unavailable'; message: string }

/** What a chat is: a launch-profile session, a bot's one Bot Chat, or a bot's side chat. */
export type ChatKind = 'session' | 'botChat' | 'sideChat'

/** Why a gateway's stored transcript could not be read to the end (HermesKit's `HistoryReadError`). */
export class HistoryReadError extends Error {
  constructor(readonly kind: 'noProgress' | 'tooLong', readonly rows?: number) {
    super(kind === 'noProgress'
      ? "This gateway's chat history cannot be read page by page. Updating Hermes fixes this."
      : `This chat has more than ${rows} messages, too many to load from this gateway. Updating Hermes fixes this.`)
  }
}

/** A stored transcript's newest rows, and whether older ones exist. */
export interface LatestHistory {
  rows: StoredMessage[]
  hasOlder: boolean
  /** Read with `order=latest` paging: the newest rows can be read again. */
  paged: boolean
}

/** Everything a chat's view paints from. Replaced whole on every change. */
export interface ChatView {
  sessionID: string
  storedSessionID?: string
  title?: string
  info?: SessionLiveInfo
  profile?: string
  kind: ChatKind
  /** The rows, oldest first (rows are immutable; compare them by identity). */
  items: readonly TranscriptItem[]
  /** `items` as the list shows them (`transcriptBlocks`). */
  blocks: readonly TranscriptBlock[]
  /** Prompts waiting in Hermes's queue; shown above the composer. */
  queuedPrompts: readonly TranscriptItem[]
  isRunning: boolean
  status?: string
  isCompacting: boolean
  waiting?: Waiting
  lastError?: string
  pendingRequests: readonly ServerRequest[]
  paging: HistoryPaging
  historyLoad: HistoryLoad
  /** The start of the conversation is on screen. */
  reachedBeginning: boolean
  isRuntimeGone: boolean
  hasPrompted: boolean
}

/** What a chat needs from its connection (`ChatManager`). */
export interface ChatHost {
  readonly client: GatewayClient | undefined
  readonly messagesSource: SessionMessagesSource | undefined
  /** Resumes a reclaimed runtime (`ChatManager.revive`). */
  revive(chat: ChatSession): Promise<void>
  /** The stored key moved (compression): remember which runtime serves it. */
  track(chat: ChatSession): void
  /** Gives text only a vanished bubble held back to the chat's composer. */
  restoreText(chat: ChatSession, text: string): void
}

/** Cancels a send while it still waits to go out (`ChatComposer.cancelSubmit`). */
export interface SendSignal {
  readonly cancelled: boolean
}

/** How `ChatSession.steer` delivered the text. */
export type SteerOutcome = 'steered' | 'sentAsPrompt' | 'ignored'

export class SendCancelledError extends Error {
  constructor() {
    super('cancelled')
  }
}

const pageSize = 120
const orderlessRowLimit = 20_000
const rereadPageLimit = 4

/**
 * One attached gateway session as the UI shows it (HermesKit's `ChatSession`): its
 * stored transcript, read in pages, then its live events. All calls go through the
 * connection's *current* client, so the same object survives reconnects. Package A
 * ports the chat core: history, streaming, send, stop and the approval, sudo and secret
 * requests. Images, files, slash commands, model pickers, subagents and background
 * processes are later packages.
 */
export class ChatSession extends Observable<ChatView> {
  /** Rows per page, Desktop's `LATEST_SESSION_MESSAGES_LIMIT`. */
  static readonly pageSize = pageSize
  static readonly orderlessRowLimit = orderlessRowLimit
  static readonly rereadPageLimit = rereadPageLimit

  sessionID: string
  storedSessionID?: string
  title?: string
  info?: SessionLiveInfo
  transcript: Transcript
  /** Highest event `seq` applied: the watermark for `session.events.since`. */
  lastSeq?: number
  readonly profile?: string
  readonly kind: ChatKind
  historyLoad: HistoryLoad = { phase: 'idle' }
  /** The backend reclaimed this chat's runtime (`session.reclaimed`); the next action resumes it. */
  isRuntimeGone = false
  /** Something was sent here from this device (a New chat is then no longer blank). */
  hasPrompted = false
  lastPromptAt?: number

  /** Whether streamed text shows a batch at a time; off in tests that count frames. */
  coalescesStreamedText = true
  private readonly streamedText = new StreamedTextQueue((events) => this.show(events))

  // Reconcile and restore bookkeeping (`ChatManager`).
  revisitTask?: Promise<void>
  isReconciling = false
  reconcileClient?: GatewayClient
  revisitToken = 0
  identityGate?: Promise<void>
  revival?: Promise<void>

  private historyGeneration = 0
  private historyKey?: string
  private historyTask?: Promise<void>
  private rereadRunning = false
  private rereadFailures = 0
  private rereadIsRetry = false
  private rereadRetryTimer?: ReturnType<typeof setTimeout>
  /** Delays before trying a failed re-read again, in ms. */
  rereadRetryDelays: number[] = [2000, 8000, 30_000]
  private readonly dispatchedPrompts = new Set<string>()
  private readonly sendingPrompts = new Set<string>()
  private readonly rebuiltDispatchedPrompts = new Set<string>()
  private viewQueued = false

  private host?: ChatHost

  /** Token use and context, fed by this chat's events (package D's gauge reads it). */
  readonly usage = new SessionUsageTracker()

  constructor(
    snapshot: LiveSessionSnapshot,
    options: { storedSessionID?: string; title?: string; profile?: string; kind?: ChatKind; host?: ChatHost } = {},
  ) {
    const transcript = Transcript.fromSnapshot(snapshot)
    const kind = options.kind ?? 'session'
    super(initialView(snapshot, transcript, kind, options))
    this.host = options.host
    this.sessionID = snapshot.session_id
    this.storedSessionID = storedKey(snapshot) ?? options.storedSessionID
    this.title = options.title ?? snapshot.info?.title ?? undefined
    this.info = snapshot.info ?? undefined
    this.usage.takeInfo(snapshot.info?.usage)
    this.transcript = transcript
    if (options.profile !== undefined) this.profile = options.profile
    this.kind = kind
    this.publish()
  }

  /** Detaches the chat from its connection (forgotten or disconnected). */
  detach(): void {
    this.streamedText.cancel()
    this.cancelRereadRetry()
    this.historyGeneration += 1
    this.host = undefined
  }

  // MARK: View

  /** Publishes a new view when anything it shows changed. */
  private publish(): void {
    const t = this.transcript
    const old = this.get()
    const items = sameRows(old.items, t.items) ? old.items : t.items.slice()
    const blocks = items === old.items && old.isRunning === t.isRunning ? old.blocks : transcriptBlocks(items, t.isRunning)
    const queuedPrompts = items === old.items ? old.queuedPrompts : items.filter(isQueuedPrompt)
    const waiting = t.waiting
    const next: ChatView = {
      sessionID: this.sessionID,
      kind: this.kind,
      items,
      blocks,
      queuedPrompts: queuedPrompts.length === 0 && old.queuedPrompts.length === 0 ? old.queuedPrompts : queuedPrompts,
      isRunning: t.isRunning,
      isCompacting: t.isCompacting,
      pendingRequests: t.pendingRequests,
      paging: samePaging(old.paging, t.paging) ? old.paging : { ...t.paging },
      historyLoad: this.historyLoad,
      reachedBeginning: t.paging.isLoaded && !t.paging.hasOlder,
      isRuntimeGone: this.isRuntimeGone,
      hasPrompted: this.hasPrompted,
      ...(this.storedSessionID !== undefined ? { storedSessionID: this.storedSessionID } : {}),
      ...(this.title !== undefined ? { title: this.title } : {}),
      ...(this.info !== undefined ? { info: this.info } : {}),
      ...(this.profile !== undefined ? { profile: this.profile } : {}),
      ...(t.status !== undefined ? { status: t.status } : {}),
      ...(waiting !== undefined ? { waiting: sameWaiting(old.waiting, waiting) ? old.waiting! : waiting } : {}),
      ...(t.lastError !== undefined ? { lastError: t.lastError } : {}),
    }
    if (shallowEqual(old, next)) return
    this.set(next)
  }

  /** Changes the transcript after showing the streamed text queued before the change. */
  private change(body: (transcript: Transcript) => void): void {
    this.streamedText.flush()
    body(this.transcript)
    this.publish()
  }

  /** Applies a batch of streamed text in one change. */
  private show(events: GatewayEvent[]): void {
    for (const event of events) this.transcript.apply(event)
    this.publish()
  }

  // MARK: Identity

  /**
   * Waits until the chat knows which runtime session it is: a revisit may still be
   * binding it again, a reconnect or a revival resuming it. A send made meanwhile would
   * go to a runtime session the chat is about to leave.
   */
  async settleIdentity(): Promise<void> {
    for (;;) {
      if (this.isReconciling && this.revisitTask) {
        const task = this.revisitTask
        await task.catch(() => {})
        if (task !== this.revisitTask) continue
      }
      const gate = this.identityGate
      if (!gate) return
      await gate.catch(() => {})
      if (gate === this.identityGate) this.identityGate = undefined
    }
  }

  /** The runtime was reclaimed: its open requests died with it, and a turn shown running. */
  markRuntimeGone(): void {
    this.isRuntimeGone = true
    this.retainRequests(new Set())
    this.change((t) => t.reconcileRunning(false))
  }

  /** Replaces local state with a fresh snapshot (after a cold resume). */
  reset(snapshot: LiveSessionSnapshot, resumedKey?: string): void {
    this.streamedText.flush()
    this.sessionID = snapshot.session_id
    this.storedSessionID = storedKey(snapshot) ?? resumedKey ?? this.storedSessionID
    if (snapshot.info) {
      this.info = snapshot.info
      if (snapshot.info.title) this.title = snapshot.info.title
    }
    // Keep stored rows while the newest page loads, and the bubbles of sends still
    // awaiting their acknowledgement; their send settles the exact local id.
    const old = this.transcript
    this.transcript = Transcript.fromSnapshot(snapshot, old.lastLocalID)
    this.transcript.holdStoredRows(old)
    this.transcript.adoptSentImages(old)
    // A dispatched prompt the snapshot runs already shows as its echo.
    const echoed = snapshot.inflight?.user != null ? userDisplayText(snapshot.inflight.user) : undefined
    const carried = new Set([...this.sendingPrompts].filter((id) =>
      !this.dispatchedPrompts.has(id) || echoed === undefined ||
      old.items.find((item) => item.id === id)?.text !== echoed))
    for (const id of carried) if (this.dispatchedPrompts.has(id)) this.rebuiltDispatchedPrompts.add(id)
    this.transcript.adoptPendingPrompts(old, carried)
    this.returnFailedPrompts(old)
    this.lastSeq = undefined
    this.isRuntimeGone = false
    this.historyGeneration += 1
    this.cancelHistoryReads()
    this.historyLoad = { phase: 'idle' }
    this.publish()
  }

  /** A failed prompt's text goes back to the composer; its error stays on screen. */
  private returnFailedPrompts(old: Transcript): void {
    const failed = old.failedPrompts
    if (failed.length === 0) return
    if (this.transcript.lastError === undefined && old.lastError !== undefined) this.transcript.keepError(old.lastError)
    const texts = failed.filter((item) => item.images.length === 0 && item.attachments.length === 0).map((item) => item.text)
    if (texts.length > 0) this.host?.restoreText(this, texts.join('\n'))
  }

  private cancelHistoryReads(): void {
    this.historyTask = undefined
    this.rereadRunning = false
    this.cancelRereadRetry()
  }

  /** After a fast-path reattach: pick up the (possibly rotated) stored key. */
  update(snapshot: LiveSessionSnapshot): void {
    const key = storedKey(snapshot)
    if (key) this.storedSessionID = key
    if (snapshot.info) this.info = snapshot.info
    this.publish()
  }

  // MARK: Stored transcript

  /**
   * Reads the newest page of the stored transcript, unless it is loaded already.
   * `prefetch` is a read of the same page started alongside the resume.
   */
  loadHistory(prefetch?: Promise<LatestHistory>): Promise<void> {
    if (this.transcript.paging.isLoaded) {
      prefetch?.catch(() => {})
      return Promise.resolve()
    }
    if (this.historyLoad.phase === 'loadingLatest' && this.historyTask) return this.historyTask
    const source = this.host?.messagesSource
    const key = this.storedSessionID
    if (!source || !key) {
      prefetch?.catch(() => {})
      this.historyLoad = { phase: 'unavailable', message: 'This connection cannot read the chat history.' }
      this.publish()
      return Promise.resolve()
    }
    const generation = ++this.historyGeneration
    this.cancelHistoryReads()
    this.historyKey = key
    this.historyLoad = { phase: 'loadingLatest' }
    this.publish()
    const query: SessionMessagesQuery = { sessionID: key, limit: pageSize, ...(this.profile !== undefined ? { profile: this.profile } : {}) }
    const task = (async () => {
      let latest: LatestHistory
      try {
        latest = await (prefetch ?? ChatSession.fetchLatest(query, source))
      } catch (error) {
        if (generation !== this.historyGeneration) return
        // A gateway that cannot page this history fails the same way every time.
        this.historyLoad = error instanceof HistoryReadError
          ? { phase: 'unavailable', message: error.message }
          : { phase: 'latestFailed', message: describeError(error) }
        this.historyTask = undefined
        this.publish()
        return
      }
      if (generation !== this.historyGeneration) return
      this.historyLoad = { phase: 'idle' }
      this.historyTask = undefined
      this.change((t) => t.installLatestPage(latest.rows, latest.hasOlder, latest.paged))
      this.rereadIfNeeded()
    })()
    this.historyTask = task
    return task
  }

  /** Reads the page just before the oldest loaded row; at most one is in flight. */
  async loadOlderMessages(): Promise<void> {
    if (!this.transcript.paging.hasOlder) return
    if (this.historyLoad.phase !== 'idle' && this.historyLoad.phase !== 'olderFailed') return
    const source = this.host?.messagesSource
    const key = this.historyKey
    if (!source || !key) return
    const generation = this.historyGeneration
    this.historyLoad = { phase: 'loadingOlder' }
    this.publish()
    const query: SessionMessagesQuery = {
      sessionID: key, limit: pageSize, offset: this.transcript.nextOlderOffset,
      ...(this.profile !== undefined ? { profile: this.profile } : {}),
    }
    try {
      const page = await source.messagesPage(query)
      if (generation !== this.historyGeneration) return
      // A short page is the first one (`hermes_state_messages.py:1409`).
      const limit = page.pagination?.limit ?? query.limit
      const hasOlder = page.pagination != null && limit > 0 && page.messages.length >= limit
      this.historyLoad = { phase: 'idle' }
      this.change((t) => t.prependOlderPage(page.messages, hasOlder))
    } catch (error) {
      if (generation !== this.historyGeneration) return
      this.historyLoad = { phase: 'olderFailed', message: describeError(error) }
      this.publish()
    }
  }

  /** Retries whichever page read failed. */
  async retryHistory(): Promise<void> {
    switch (this.historyLoad.phase) {
      case 'latestFailed':
        this.historyLoad = { phase: 'idle' }
        await this.loadHistory()
        return
      case 'olderFailed':
        await this.loadOlderMessages()
        return
      default:
        return
    }
  }

  /**
   * The newest page, `order=latest` (`web_routers/sessions.py:685-729`):
   * - no `pagination` (a gateway older than paging): the whole history;
   * - `pagination.order` other than `latest` (a gateway that ignores `order`): the page
   *   holds the oldest rows; a short page is still everything, else the rest is read
   *   oldest first, 500 rows a page, bounded, like Desktop's
   *   `completeTranscriptForOrderlessBackend`.
   */
  static async fetchLatest(query: SessionMessagesQuery, source: SessionMessagesSource): Promise<LatestHistory> {
    const page = await source.messagesPage(query)
    const pagination = page.pagination
    const limit = pagination?.limit
    if (!pagination || !limit || limit <= 0) return { rows: page.messages, hasOlder: false, paged: false }
    if (pagination.order === 'latest') return { rows: page.messages, hasOlder: page.messages.length >= limit, paged: true }
    if (page.messages.length < limit) return { rows: page.messages, hasOlder: false, paged: false }
    const rows = [...page.messages]
    const seen = new Set(rows.flatMap((row) => typeof row.id === 'number' ? [row.id] : []))
    let last: SessionMessagesPage = page
    for (;;) {
      const lastLimit = last.pagination?.limit
      if (!lastLimit || lastLimit <= 0 || last.messages.length === 0 || last.messages.length < lastLimit) break
      if (rows.length >= orderlessRowLimit) throw new HistoryReadError('tooLong', orderlessRowLimit)
      last = await source.messagesPage({
        sessionID: query.sessionID, order: 'oldest', limit: 500, offset: rows.length,
        ...(query.profile !== undefined ? { profile: query.profile } : {}),
      })
      const fresh = last.messages.filter((row) => {
        if (typeof row.id !== 'number') return true
        if (seen.has(row.id)) return false
        seen.add(row.id)
        return true
      })
      if (last.messages.length === 0) break
      if (fresh.length === 0) throw new HistoryReadError('noProgress')
      rows.push(...fresh)
    }
    return { rows, hasOlder: false, paged: false }
  }

  /**
   * Shown again after a while and bound to this socket again (`ChatManager.revisit`):
   * read the newest rows again, or the newest page if none was read yet.
   */
  reconcileAfterRevisit(running: boolean): void {
    this.change((t) => t.reconcileRunning(running))
    if (this.transcript.paging.isLoaded) {
      this.change((t) => t.requestReread())
      this.rereadIfNeeded()
    } else if (this.historyLoad.phase !== 'loadingLatest') {
      this.historyLoad = { phase: 'idle' }
      void this.loadHistory()
    }
  }

  /** Drops pending requests the server no longer lists as open. */
  retainRequests(ids: ReadonlySet<string>): void {
    const gone = this.transcript.pendingRequests.filter((request) => !ids.has(request.id))
    if (gone.length === 0) return
    this.change((t) => { for (const request of gone) t.removeRequest(request.id) })
  }

  // MARK: Events

  apply(event: GatewayEvent): void {
    if (typeof event.seq === 'number' && event.session_id === this.sessionID) {
      this.lastSeq = Math.max(this.lastSeq ?? 0, event.seq)
    }
    if (event.type.startsWith('subagent.')) return  // package C/G
    this.usage.observe(event)
    const kind = eventKind(event)
    if (kind.kind === 'messageDelta' || kind.kind === 'reasoningDelta') {
      if (this.coalescesStreamedText) {
        this.streamedText.append(event)
        return
      }
    } else {
      // After the text streamed before it, as Desktop flushes its queue first.
      this.streamedText.flush()
    }
    switch (kind.kind) {
      case 'sessionTitle':
        if (kind.change.session_id === this.storedSessionID || kind.change.session_id === this.sessionID) {
          this.title = kind.change.title
          this.publish()
        }
        return
      case 'sessionInfo':
        this.applyInfo(kind.info)
        return
      default:
        this.transcript.apply(event)
        this.publish()
        this.rereadIfNeeded()
    }
  }

  private applyInfo(info: SessionLiveInfo): void {
    this.info = info
    this.usage.takeInfo(info.usage)
    // A turn that ended without `message.complete` ends here too.
    if (info.running === false && this.transcript.isRunning) {
      this.transcript.serverReportsIdle()
      if (!this.transcript.isRunning) this.transcript.requestReread()
    }
    if (info.title) this.title = info.title
    // Compression can rotate the stored key mid-session.
    const key = info.stored_session_id
    if (key && key !== this.storedSessionID) {
      this.storedSessionID = key
      this.host?.track(this)
    }
    this.publish()
    this.rereadIfNeeded()
  }

  setTitle(title: string): void {
    this.title = title
    this.publish()
  }

  // MARK: Re-reading the newest rows

  /**
   * A turn finished (`Transcript.needsReread`): read the newest rows again and let the
   * transcript rebuild its tail from them. Bounded to `rereadPageLimit` pages; one at a
   * time; a failed one is retried after `rereadRetryDelays`.
   */
  rereadIfNeeded(): void {
    if (!this.transcript.needsReread || this.rereadRunning) return
    const source = this.host?.messagesSource
    const key = this.historyKey ?? this.storedSessionID
    if (!source || !key) return
    const ticket = this.transcript.beginReread()
    const generation = this.historyGeneration
    if (!this.rereadIsRetry) this.rereadFailures = 0
    const shown = this.transcript
    const profile = this.profile
    this.rereadRunning = true
    void (async () => {
      let rows: StoredMessage[] = []
      let reachesStart = false
      let failed = false
      try {
        for (let page = 0; page < rereadPageLimit; page += 1) {
          const read = await source.messagesPage({
            sessionID: key, limit: pageSize, offset: page * pageSize, ...(profile !== undefined ? { profile } : {}),
          })
          rows = [...read.messages, ...rows]
          reachesStart = read.messages.length < pageSize
          if (reachesStart || shown.holdsAny(read.messages)) break
        }
      } catch {
        rows = []
        failed = true
      }
      if (generation !== this.historyGeneration) return
      this.rereadRunning = false
      this.change((t) => t.installRereadPage(rows, ticket, reachesStart))
      if (failed) this.retryReread(generation)
      else this.rereadFailures = 0
      this.rereadIfNeeded()
    })()
  }

  private retryReread(generation: number): void {
    if (this.rereadFailures >= this.rereadRetryDelays.length) return
    const delay = this.rereadRetryDelays[this.rereadFailures]!
    this.rereadFailures += 1
    if (this.rereadRetryTimer !== undefined) clearTimeout(this.rereadRetryTimer)
    this.rereadRetryTimer = setTimeout(() => {
      this.rereadRetryTimer = undefined
      if (generation !== this.historyGeneration) return
      this.transcript.requestReread()
      this.rereadIsRetry = true
      this.rereadIfNeeded()
      this.rereadIsRetry = false
    }, delay)
  }

  cancelRereadRetry(): void {
    if (this.rereadRetryTimer !== undefined) clearTimeout(this.rereadRetryTimer)
    this.rereadRetryTimer = undefined
    this.rereadFailures = 0
  }

  receive(request: ServerRequest): void {
    this.change((t) => t.addRequest(request))
  }

  // MARK: Actions

  /**
   * Shows the prompt at once, then submits it; the reply streams in as events. Until
   * `prompt.submit` goes out, `signal` can still cancel the send (the bubble goes and
   * `SendCancelledError` is thrown, so the composer takes the text back). Once it went
   * out it is never cancelled: Hermes may run it. A failure after that keeps the bubble,
   * marked as not confirmed. `display` is what the bubble shows instead of `text` (a
   * skill's invocation, never its expanded body).
   */
  async send(text: string, signal?: SendSignal, display?: string): Promise<void> {
    const trimmed = text.trim()
    if (trimmed === '') return
    this.hasPrompted = true
    this.lastPromptAt = Date.now()
    let itemID = ''
    this.change((t) => { itemID = t.appendUserPrompt(display?.trim() || trimmed) })
    this.sendingPrompts.add(itemID)
    try {
      await this.performSend(trimmed, itemID, signal)
    } catch (error) {
      const dispatched = this.dispatchedPrompts.has(itemID)
      if (!dispatched && (error instanceof SendCancelledError || isNotConnected(error))) {
        // Nothing went out and the composer takes the text back: the bubble goes.
        this.change((t) => t.withdrawPrompt(itemID))
      } else if (this.transcript.holdsPrompt(itemID)) {
        // Only the bubble holds the text. A dispatched submit may have run.
        this.change((t) => t.submitFailed(describeError(error), itemID, dispatched))
      }
      throw error
    } finally {
      this.sendingPrompts.delete(itemID)
      this.dispatchedPrompts.delete(itemID)
      this.rebuiltDispatchedPrompts.delete(itemID)
    }
  }

  private async performSend(prompt: string, itemID: string, signal?: SendSignal): Promise<void> {
    await this.settleIdentity()
    if (signal?.cancelled) throw new SendCancelledError()
    let reviveError: unknown
    try {
      await this.reviveIfGone()
    } catch (error) {
      reviveError = error
    }
    if (signal?.cancelled) throw new SendCancelledError()
    try {
      if (reviveError !== undefined) throw reviveError
      const client = this.currentClient()
      this.dispatchedPrompts.add(itemID)
      const answer = await client.call(SessionMethod.promptSubmit, { session_id: this.sessionID, text: prompt },
        promptSubmitTimeoutMs) as { status?: string; user_row_id?: number } | null
      this.promptAnswered(itemID, answer?.status ?? undefined, answer?.user_row_id ?? undefined)
    } catch (error) {
      if (this.rebuiltDispatchedPrompts.has(itemID)) this.change((t) => t.withdrawPrompt(itemID))
      if (!this.transcript.holdsPrompt(itemID) && !(isNotConnected(error) && !this.dispatchedPrompts.has(itemID))) {
        // A rebuild replaced the bubble meanwhile: its text goes back to the draft.
        this.change((t) => t.keepError(describeError(error)))
        this.host?.restoreText(this, prompt)
      }
      throw error
    }
  }

  /** `prompt.submit` answered: the bubble shows until the stored rows replace it. */
  private promptAnswered(itemID: string, status?: string, userRowID?: number): void {
    if (this.transcript.holdsPrompt(itemID)) this.change((t) => t.promptAnswered(itemID, status, userRowID))
    else this.change((t) => t.requestReread())
    if (this.rebuiltDispatchedPrompts.has(itemID)) this.change((t) => t.requestReread())
    this.rereadIfNeeded()
  }

  /** Stops the running turn. A reclaimed runtime has nothing running. */
  async interrupt(): Promise<void> {
    if (this.isRuntimeGone) return
    const client = this.currentClient()
    // Their submits reach Hermes before the Stop: one answered `queued` was cleared by it.
    const sentBeforeStop = this.transcript.unansweredPrompts
    const result = await client.call(SessionMethod.sessionInterrupt, { session_id: this.sessionID }) as { status?: string } | null
    // Hermes cleared its queue with the Stop; only a hosted-task check answers `not_interrupted`.
    if (result?.status !== 'not_interrupted') this.change((t) => t.serverClearedQueue(sentBeforeStop))
  }

  /** Where this chat's stored rows are read (package G reads them whole to branch). */
  get messagesSource(): SessionMessagesSource | undefined {
    return this.host?.messagesSource
  }

  /** Shows an action's failure in the chat's error line (package G: a branch refused). */
  showError(message: string): void {
    this.change((t) => t.keepError(message))
  }

  /** Adds a note only this device shows (`displayKind`: e.g. `compression`). */
  appendLocalNote(text: string, displayKind?: string): void {
    this.change((t) => t.appendNote(text, displayKind))
  }

  /** Shows a `/btw` question or `/bg` task until its answer arrives (package D's slash commands). */
  beginSideQuestion(taskID: string, question: string, kind: 'btw' | 'background'): void {
    this.change((t) => t.beginSideQuestion(taskID, question, kind))
  }

  /** Sets the model, provider or effort the chat shows, before `session.info` confirms it (package D). */
  showInfo(change: Partial<SessionLiveInfo>): void {
    this.info = { ...this.info, ...change }
    this.publish()
  }

  // MARK: Server requests

  /** Answers an approval card; `all` approves every pending request of the batch. */
  answerApproval(request: ServerRequest, choice: ApprovalChoice, all = false): void {
    const result: Record<string, JSONValue> = { choice }
    if (all) result.all = true
    this.currentClient().respond(request.id, { result })
    this.change((t) => t.removeRequest(request.id))
  }

  /** Answers a sudo or secret card; an empty value skips it. */
  answerValue(request: ServerRequest, value: string): void {
    this.currentClient().respond(request.id, { result: { value } })
    this.change((t) => t.removeRequest(request.id))
  }

  // MARK: Steer, compress, clarify (package F)

  /**
   * Hands guidance to the running turn (`session.steer`, `methods_session.py:2444-2482`):
   * the agent sees it with its next tool result, without a new user turn. The chat shows
   * it as a `steer` prompt until the stored row replaces it. With no turn running the
   * gateway answers `rejected`, and the text goes as a normal prompt instead.
   */
  async steer(text: string): Promise<SteerOutcome> {
    const trimmed = text.trim()
    if (trimmed === '') return 'ignored'
    const client = await this.liveClient()
    const result = await client.call(SessionMethod.sessionSteer, { session_id: this.sessionID, text: trimmed }) as { status?: string } | null
    if (result?.status !== 'queued') {
      await this.send(trimmed)
      return 'sentAsPrompt'
    }
    this.hasPrompted = true
    let itemID = ''
    this.change((t) => { itemID = t.appendUserPrompt(trimmed, { displayKind: 'steer' }) })
    this.promptAnswered(itemID, 'steered')
    return 'steered'
  }

  /**
   * Compresses the conversation's context (`session.compress`, `/compress`), optionally
   * on a topic. As on Desktop the earlier messages stay and the result line
   * (`compressionMessage`) is added, centred, as a divider. Returns that line.
   */
  async compress(focusTopic?: string): Promise<string> {
    const client = await this.liveClient()
    const topic = focusTopic?.trim()
    const params: Record<string, JSONValue> = { session_id: this.sessionID }
    if (topic) params.focus_topic = topic
    const result = await client.call(SessionMethod.sessionCompress, params, sessionCompressTimeoutMs) as SessionCompressResult | null
    if (result?.info && typeof result.info === 'object') this.applyInfo(result.info as SessionLiveInfo)
    const message = compressionMessage(result)
    this.change((t) => t.appendNote(message, compressionDisplayKind))
    return message
  }

  /**
   * Answers a clarify card with every question at once (`{qid: answer}`, `null` = that
   * question skipped); `null` for the whole map cancels the request (HermesKit's
   * `answer(_:clarify:)`).
   */
  answerClarify(request: ServerRequest, answers: Readonly<Record<string, string | null>> | null): void {
    this.currentClient().respond(request.id, { result: { answers: answers === null ? null : { ...answers } } })
    this.change((t) => t.removeRequest(request.id))
  }

  // MARK: Clients

  private currentClient(): GatewayClient {
    const client = this.host?.client
    if (!client) throw new GatewayClientError('notConnected')
    return client
  }

  /** Resumes a reclaimed runtime from its stored key first. */
  private async reviveIfGone(): Promise<void> {
    if (!this.isRuntimeGone) return
    if (!this.host) throw new GatewayClientError('notConnected')
    await this.host.revive(this)
  }

  /** The current client, once the chat knows its runtime and that runtime is live. */
  async liveClient(): Promise<GatewayClient> {
    await this.settleIdentity()
    await this.reviveIfGone()
    return this.currentClient()
  }

  /** The renderer key of each block, for tests and the registry. */
  static blockKind = blockKind
}

function isNotConnected(error: unknown): boolean {
  return error instanceof GatewayClientError && error.kind === 'notConnected'
}

function initialView(snapshot: LiveSessionSnapshot, transcript: Transcript, kind: ChatKind,
  options: { storedSessionID?: string; title?: string; profile?: string }): ChatView {
  const items = transcript.items.slice()
  return {
    sessionID: snapshot.session_id,
    kind,
    items,
    blocks: transcriptBlocks(items, transcript.isRunning),
    queuedPrompts: [],
    isRunning: transcript.isRunning,
    isCompacting: false,
    pendingRequests: transcript.pendingRequests,
    paging: { ...transcript.paging },
    historyLoad: { phase: 'idle' },
    reachedBeginning: false,
    isRuntimeGone: false,
    hasPrompted: false,
    ...(options.profile !== undefined ? { profile: options.profile } : {}),
  }
}

function sameRows(a: readonly TranscriptItem[], b: readonly TranscriptItem[]): boolean {
  if (a.length !== b.length) return false
  for (let index = 0; index < a.length; index += 1) if (a[index] !== b[index]) return false
  return true
}

function samePaging(a: HistoryPaging, b: HistoryPaging): boolean {
  return a.isLoaded === b.isLoaded && a.hasOlder === b.hasOlder && a.rowsLoaded === b.rowsLoaded && a.rereadable === b.rereadable
}

function sameWaiting(a: Waiting | undefined, b: Waiting): boolean {
  return a !== undefined && JSON.stringify(a) === JSON.stringify(b)
}

function shallowEqual(a: ChatView, b: ChatView): boolean {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]) as Set<keyof ChatView>
  for (const key of keys) if (a[key] !== b[key]) return false
  return true
}
