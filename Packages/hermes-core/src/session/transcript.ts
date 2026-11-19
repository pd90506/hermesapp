import type { GatewayEvent } from '../client.ts'
import type { JSONValue } from '../protocol/jsonrpc.ts'
import {
  attachmentDisplayName, isQueuedPrompt, isSteer, makeItem, queuedStatus, reviewDisplayKind, splitImageDirectives,
  splitLeadingAttachmentRefs, storedImages, userTurn,
  type SideQuestion, type ToolActivity, type TranscriptImage, type TranscriptItem, type TranscriptRole,
} from './items.ts'
import {
  asArray, displayText, objectAt, preview, storedItems, storedResult, stringAt, toolArguments, userDisplayText,
  type ToolCalls,
} from './stored-projection.ts'
import {
  completeText, eventKind, inflightIsFailed, requestKind, stableStringify,
  type GatewayEventKind, type LiveSessionSnapshot, type MessageComplete, type ServerRequest, type SideAgentComplete,
  type StatusUpdate, type StoredMessage, type TranscriptMessage,
} from './types.ts'

/** Paging position of the stored part of a transcript (HermesKit's `HistoryPaging`). */
export interface HistoryPaging {
  /** The latest page (or the whole history) is in. */
  isLoaded: boolean
  /** Rows exist before the oldest loaded one. */
  hasOlder: boolean
  /** Rows received in pages, hidden ones included: the server's `offset` unit. */
  rowsLoaded: number
  /** The newest rows can be read again in bounded pages. */
  rereadable: boolean
}

/** What a re-read of the newest rows may settle (`Transcript.beginReread()`). */
export interface RereadTicket {
  readonly clock: number
  readonly completions: number
  readonly starts: number
}

/** The waiting row: from a send until the reply shows text or a tool row. */
export interface Waiting {
  /** Unix ms when the prompt was sent here; undefined for a turn this chat did not start. */
  since?: number
  hint?: string
}

export function waitingLabel(waiting: Waiting): string {
  return waiting.hint ?? 'Thinking…'
}

/** Elapsed time as the waiting row shows it: `4s`, `1m 05s`, `1h 02m`. */
export function elapsedText(startMs: number, nowMs: number): string {
  const two = (value: number) => (value < 10 ? `0${value}` : `${value}`)
  const seconds = Math.max(0, Math.floor((nowMs - startMs) / 1000))
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ${two(seconds % 60)}s`
  return `${Math.floor(minutes / 60)}h ${two(minutes % 60)}m`
}

type PromptState =
  | { state: 'sent' }
  | { state: 'answered'; clock: number; storedRow?: number }
  | { state: 'failed' }

interface LateTail { itemID: string; promptID: string; keepsRound: boolean }
interface InflightEcho { prompt: string; reply: string }

/** `message.complete`'s text for a reply stopped as a repetition loop (`agent/repetition_guard.py:29`). */
export const repetitionLoopSentinel = '[the reply degenerated into a repetition loop and was interrupted]'
/** `_AGENT_BUILD_SLOW_NOTICE_KEY` (`tui_gateway/server.py:945`). */
const buildNoticeKey = 'agent-build-slow'
/** Rows an older page re-reads from the loaded window. */
export const olderPageOverlap = 10

const isWS = (character: string) => /\s/.test(character)

/** Every run of whitespace one space, trimmed (`_normalize_interim_visible_text`). */
export function normalizedText(text: string): string {
  return text.split(/\s+/).filter(Boolean).join(' ')
}

/** Text with no whitespace at all. */
export function squeezed(text: string): string {
  return text.replace(/\s+/g, '')
}

/** `text` without the prefix `stored` holds, whitespace aside (Desktop's `unrepresentedText`). */
export function unrepresented(text: string, stored: string): string {
  const wanted = [...squeezed(stored)]
  if (wanted.length === 0) return text
  const chars = [...text]
  let index = 0
  let next = 0
  while (index < chars.length && next < wanted.length) {
    const character = chars[index]!
    if (!isWS(character)) {
      if (character !== wanted[next]) return text
      next += 1
    }
    index += 1
  }
  if (next < wanted.length) return ''
  return chars.slice(index).join('').replace(/^\s+/, '')
}

export function isVisibleOutput(item: TranscriptItem): boolean {
  return item.role === 'tool' || (item.role === 'assistant' && item.text.trim() !== '')
}

/** A tool result as display text: strings as-is, other JSON serialised. */
function resultText(value: JSONValue | undefined): string | undefined {
  if (value === undefined || value === null) return undefined
  if (typeof value === 'string') return value
  return stableStringify(value)
}

export function toolItemID(toolID: string): string {
  return 'tool-' + toolID
}

export function sideQuestionItemID(taskID: string, kind: SideQuestion['kind'] = 'btw'): string {
  return (kind === 'btw' ? 'btw-' : 'bg-') + taskID
}

/** `message.start` and the turn's own events that end a compaction's row. */
function showsTheTurnMovedOn(kind: GatewayEventKind['kind']): boolean {
  return ['messageDelta', 'reasoningDelta', 'thinkingDelta', 'messageInterim', 'toolGenerating', 'toolStart'].includes(kind)
}

/** Whether `update` starts (`true`) or ends (`false`) a compaction; undefined otherwise. */
export function compactionEdge(update: StatusUpdate): boolean | undefined {
  switch (update.kind) {
    case 'compacting': case 'compressing': return true
    case 'compacted': case 'ready': return false
    case 'status': return update.text === 'ready' ? false : undefined
    default: return undefined
  }
}

const recallSegment = '\\S+ .+? — recalled (?:\\d+ memories|1 memory|relevant memory)'
const recallIndicator = new RegExp(`^${recallSegment}(?:  ${recallSegment})*$`, 'u')

/** The memory provider's per-turn recall line ("👁 Hindsight — recalled 58 memories"), not shown. */
export function isMemoryRecallIndicator(update: StatusUpdate): boolean {
  return update.kind === 'lifecycle' && recallIndicator.test(update.text.trim())
}

/** Desktop's `providerWaitText` (`store/provider-wait.ts:43-53`). */
export function providerWaitText(text: string): string | undefined {
  const value = text.trim()
  const pattern = /^(?:⏳|⚠|↻|⚙)\s*(?:(?:still\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))/iu
  return pattern.test(value) ? value : undefined
}

const providerWaitSuperseding = new Set([
  'error', 'message.complete', 'message.delta', 'message.interim', 'message.start', 'reasoning.available',
  'reasoning.delta', 'tool.complete', 'tool.generating', 'tool.start',
])
const draftSuperseding = new Set([
  'error', 'message.complete', 'message.delta', 'message.start', 'reasoning.delta', 'thinking.delta',
  'tool.complete', 'tool.start',
])

/** Events of the turn that end the old reply's late text (`endsLateTail`). */
function endsLateTail(kind: GatewayEventKind['kind']): boolean {
  switch (kind) {
    case 'messageDelta': case 'statusUpdate': case 'btwComplete': case 'backgroundComplete': case 'reviewSummary':
    case 'requestCancel': case 'approvalCancelled': case 'notificationShow': case 'notificationClear':
    case 'gatewayReady': case 'sessionTitle': case 'sessionInfo': case 'sessionsChanged': case 'sessionReclaimed':
    case 'unknown':
      return false
    default:
      return true
  }
}

function plainText(message: TranscriptMessage): string {
  if (typeof message.text === 'string') return message.text
  const content = message.content
  if (typeof content === 'string') return content
  if (Array.isArray(content)) return content.flatMap((part) => (stringAt(part, 'text') !== undefined ? [stringAt(part, 'text')!] : [])).join('\n')
  return ''
}

const subtract = <T>(set: Set<T>, other: Iterable<T>) => { for (const value of other) set.delete(value) }
const intersect = <T>(set: Set<T>, other: Set<T>) => { for (const value of [...set]) if (!other.has(value)) set.delete(value) }
const maxOf = (values: Iterable<number>): number | undefined => {
  let best: number | undefined
  for (const value of values) if (best === undefined || value > best) best = value
  return best
}

/**
 * Pure reducer from gateway snapshots, stored pages and events to a display transcript,
 * a port of HermesKit's `Transcript` (see its documentation and `docs/protocol.md` §4–§5,
 * which hold the reasons behind every rule here).
 *
 * **The stored rows are the source of truth.** `items[0, historyCount)` are stored rows,
 * oldest first; the rest are live items: the turn streaming now, prompts sent here, and
 * finished turns until a re-read of the newest rows shows what was stored. Live and
 * stored content are never matched by text.
 *
 * Rows are immutable objects: a change replaces the row, so views can compare rows by
 * identity. The transcript itself is mutable; `ChatSession` publishes a `view()` after
 * every change.
 */
export class Transcript {
  items: TranscriptItem[] = []
  historyCount = 0
  paging: HistoryPaging = { isLoaded: false, hasOlder: false, rowsLoaded: 0, rereadable: false }
  isRunning = false
  status?: string
  isCompacting = false
  providerWait?: string
  generatingTool?: string
  buildNotice?: string
  lastError?: string
  pendingRequests: ServerRequest[] = []
  needsReread = false
  lastPromptID?: string

  private counter = 0
  private heldRowIDs = new Set<number>()
  private hiddenOpening?: StoredMessage
  private turnItemIDs = new Set<string>()
  private turnActive = false
  private finishedItems = new Map<string, number>()
  private receiptRowByCompletion = new Map<number, number>()
  private unstoredByReceipt = new Map<string, Set<number>>()
  private prompts = new Map<string, PromptState>()
  private rebuiltPendingPrompts = new Set<string>()
  private quietOnce = new Set<string>()
  private promptSentAtStarts = new Map<string, number>()
  private lastSentAt?: number
  private expectedStarts = new Set<string>()
  private queuedStarts = new Set<string>()
  private queueClearedBeforeAnswer = new Set<string>()
  private newestReceiptRow = 0
  private openTurnRowFloor = 0
  private serverBusy = false
  private turnPromptRow?: number
  private outputSinceWait = false
  private rereadWhenLoaded = false
  private readsPromptAtFirstOutput = false
  private awaitingTurn = new Set<string>()
  private clock = 0
  private completions = 0
  private starts = 0
  private buildingHistory = false
  private localIDs = new Set<string>()
  private sentImages = new Map<number, readonly TranscriptImage[]>()
  private localAnchors = new Map<string, number>()
  private lateTail?: LateTail
  private inflightEcho?: InflightEcho

  /**
   * Rebuilds from `session.resume` / `session.activate` / `session.create`. A resume with
   * `omit_messages` carries no messages: the history arrives with `installLatestPage`.
   * `localIDsAfter`: live items are numbered above the ids the replaced transcript used.
   */
  static fromSnapshot(snapshot: LiveSessionSnapshot, localIDsAfter = 0): Transcript {
    const t = new Transcript()
    t.counter = localIDsAfter
    t.buildingHistory = true
    for (const message of snapshot.messages ?? []) {
      const rowID = typeof message.row_id === 'number' ? message.row_id : undefined
      switch (message.role) {
        case 'user': {
          const index = t.appendUser(plainText(message), rowID)
          if (message.display_kind) t.edit(index, { displayKind: message.display_kind })
          break
        }
        case 'assistant': {
          const text = plainText(message)
          if (text === '' && (message.reasoning === undefined || message.reasoning === null)) continue
          const index = t.append('assistant', text, false, rowID)
          t.edit(index, { reasoning: message.reasoning ?? '' })
          break
        }
        case 'tool': {
          const id = rowID !== undefined ? `row-${rowID}` : t.nextID()
          const tool: ToolActivity = { toolID: message.tool_call_id ?? id, name: message.name ?? 'tool', phase: 'complete' }
          if (message.context) tool.context = message.context
          if (message.args !== undefined) tool.args = message.args
          if (typeof message.content === 'string') {
            tool.output = message.content
            tool.result = storedResult(message.content)
          } else {
            tool.result = message.context ? { context: message.context } : {}
          }
          t.items.push({
            ...makeItem(id, 'tool', ''),
            ...(message.name ? { toolName: message.name } : {}),
            ...(message.context ? { detail: message.context } : {}),
            ...(rowID !== undefined ? { rowID } : {}),
            ...(message.tool_call_id ? { toolCallID: message.tool_call_id } : {}),
            tool,
          })
          break
        }
        case 'system':
          t.append('system', plainText(message), false, rowID)
          break
        default:
          continue
      }
    }
    t.buildingHistory = false
    t.historyCount = t.items.length
    t.heldRowIDs = new Set(t.items.flatMap((item) => (item.rowID !== undefined ? [item.rowID] : [])))
    const omitted = (snapshot.hydrating !== undefined && snapshot.hydrating !== null) || snapshot.messages_omitted === true
    const messages = snapshot.messages ?? []
    const messageCount = snapshot.message_count ?? messages.length
    if (messages.length > 0 || (messageCount === 0 && !omitted)) {
      t.paging = { isLoaded: true, hasOlder: false, rowsLoaded: messages.length, rereadable: messages.length === 0 }
    }
    const inflight = snapshot.inflight
    if (inflight) {
      const failed = inflightIsFailed(inflight)
      if (!failed) t.startTurn()
      let echo: string | undefined
      const user = inflight.user ? userDisplayText(inflight.user) : undefined
      const last = t.items[t.items.length - 1]
      if (user && (last?.role !== 'user' || last.text !== user)) {
        echo = t.items[t.appendUser(user)]!.id
      }
      const assistant = inflight.assistant ?? ''
      if (failed) {
        if (assistant !== '') {
          const index = t.append('assistant', assistant)
          t.edit(index, { outcome: inflight.status ?? 'error' })
        }
        t.lastError = inflight.error ?? undefined
        t.turnItemIDs = new Set()
        if (echo) t.finishedItems.set(echo, t.completions)
        t.serverBusy = snapshot.running === true
      } else {
        const streaming = inflight.streaming ?? (snapshot.running === true)
        const reply = t.items[t.append('assistant', assistant, streaming)]!.id
        if (echo) t.inflightEcho = { prompt: echo, reply }
      }
    } else if (snapshot.running === true) {
      t.startTurn()
    }
    t.refreshRunning()
    t.outputSinceWait = t.live().some(isVisibleOutput)
    return t
  }

  // MARK: - Reading

  /** Prompts Hermes queued behind the running turn, oldest first: the composer shows them. */
  get queuedPrompts(): TranscriptItem[] {
    return this.live().filter(isQueuedPrompt)
  }

  /** Prompts sent here whose submit is not answered yet. */
  get unansweredPrompts(): Set<string> {
    return new Set([...this.prompts].filter(([, state]) => state.state === 'sent').map(([id]) => id))
  }

  /** Prompts sent here whose submit failed: only their bubble holds them. */
  get failedPrompts(): TranscriptItem[] {
    return this.live().filter((item) => this.prompts.get(item.id)?.state === 'failed')
  }

  /** Whether `itemID` is a prompt sent here that this transcript still shows. */
  holdsPrompt(itemID: string): boolean {
    return this.prompts.has(itemID)
  }

  /** The highest `local-n` number used. */
  get lastLocalID(): number {
    return this.counter
  }

  /** Where the next older page starts (Desktop's `transcript-tail.ts:132-153`, less a margin). */
  get nextOlderOffset(): number {
    return Math.max(0, this.paging.rowsLoaded - olderPageOverlap)
  }

  /** Whether any of `rows` is one the history already holds. */
  holdsAny(rows: readonly StoredMessage[]): boolean {
    return rows.some((row) => typeof row.id === 'number' && this.heldRowIDs.has(row.id))
  }

  /** The reply is awaited and nothing of it shows yet. */
  get waiting(): Waiting | undefined {
    if (!this.isRunning || this.outputSinceWait) return undefined
    const waiting: Waiting = {}
    if (this.lastSentAt !== undefined) waiting.since = this.lastSentAt
    const hint = this.waitingHint
    if (hint !== undefined) waiting.hint = hint
    return waiting
  }

  private get waitingHint(): string | undefined {
    if (this.status) return this.status
    if (this.providerWait) return this.providerWait
    if (this.generatingTool) return `Drafting ${this.generatingTool}…`
    return this.buildNotice
  }

  // MARK: - Stored pages

  /** Replaces the history with the newest page (`order=latest`, chronological). */
  installLatestPage(rows: readonly StoredMessage[], hasOlder: boolean, rereadable = true): void {
    this.replaceHistory(0, rows, !hasOlder)
    this.heldRowIDs = new Set(rowIDs(rows))
    this.paging = { isLoaded: true, hasOlder, rowsLoaded: rows.length, rereadable }
    this.hiddenOpening = hasOlder ? hiddenFirstPrompt(rows) : undefined
    if (rereadable && (this.rereadWhenLoaded || this.finishedItems.size > 0
      || [...this.prompts.values()].some((state) => state.state === 'answered'))) {
      this.needsReread = true
    }
    this.rereadWhenLoaded = false
    this.adoptStoredOpenTurn(rows)
    this.dropPromptsShownByRows()
    this.absorbLocalRows()
  }

  /** The running turn a snapshot showed becomes the stored rows' turn (`adoptStoredOpenTurn`). */
  private adoptStoredOpenTurn(rows: readonly StoredMessage[]): void {
    const echo = this.inflightEcho
    if (!echo) return
    this.inflightEcho = undefined
    if (!this.turnItemIDs.has(echo.prompt)) return
    const prompt = this.live().find((item) => item.id === echo.prompt)
    if (!prompt) return
    const wanted = normalizedText(prompt.text)
    const history = this.items.slice(0, this.historyCount)
    let start: number | undefined
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      const row = rows[index]!
      if (row.role === 'assistant' && asArray(row.tool_calls).length === 0 && normalizedText(displayText(row)) !== '') break
      if (row.role !== 'user' || row.display_kind === 'steer' || typeof row.id !== 'number') continue
      const id = row.id
      if (!history.some((item) => item.rowID === id && item.role === 'user' && normalizedText(item.text) === wanted)) continue
      start = index
      break
    }
    if (start === undefined) return
    const promptRow = rows[start]!.id
    if (typeof promptRow !== 'number') return
    const after = rows.slice(start + 1)
    if (after.some((row) => row.role === 'user' && row.display_kind !== 'steer')) return
    this.turnItemIDs.delete(echo.prompt)
    this.removeLiveItems((item) => item.id === echo.prompt)
    this.turnPromptRow = promptRow
    this.openTurnRowFloor = Math.max(this.openTurnRowFloor, maxOf(this.heldRowIDs) ?? 0)
    const stored = after.filter((row) => row.role === 'assistant' && row.display_kind !== 'hidden')
      .map(displayText).join('\n\n')
    let reply = this.lastLiveIndex((item) => item.id === echo.reply)
    if (reply !== undefined) this.edit(reply, { text: unrepresented(this.items[reply]!.text, stored) })
    const answered = new Set(after.flatMap((row) => (row.role === 'tool' && row.tool_call_id ? [row.tool_call_id] : [])))
    const running: TranscriptItem[] = []
    for (const row of after) {
      if (row.role !== 'assistant') continue
      for (const call of asArray(row.tool_calls)) {
        const id = stringAt(call, 'id')
        const name = stringAt(objectAt(call, 'function'), 'name')
        if (!id || answered.has(id) || !name || this.items.some((item) => item.id === toolItemID(id))) continue
        const args = toolArguments(objectAt(call, 'function')?.arguments)
        const detail = preview(args)
        const tool: ToolActivity = { toolID: id, name, phase: 'running' }
        if (detail !== undefined) tool.context = detail
        if (Object.keys(args).length > 0) tool.args = args
        running.push({
          ...makeItem(toolItemID(id), 'tool', '', true),
          toolCallID: id, toolName: name, ...(detail !== undefined ? { detail } : {}), tool,
        })
      }
    }
    reply = this.lastLiveIndex((item) => item.id === echo.reply)
    this.items.splice(reply ?? this.items.length, 0, ...running)
    for (const item of running) this.turnItemIDs.add(item.id)
    this.outputSinceWait = this.live().some(isVisibleOutput)
  }

  /** Holds `old`'s stored rows on screen while this transcript's newest page loads. */
  holdStoredRows(old: Transcript): void {
    if (this.items.length > 0 || this.paging.isLoaded) return
    this.items = old.items.slice(0, old.historyCount).filter((item) => !old.localIDs.has(item.id))
    this.historyCount = this.items.length
  }

  /** Prepends the page just before the loaded rows, cut at its first held row. */
  prependOlderPage(rows: readonly StoredMessage[], hasOlder: boolean): void {
    this.paging = { ...this.paging, rowsLoaded: this.paging.rowsLoaded + rows.length }
    let firstHeld = rows.findIndex((row) => typeof row.id === 'number' && this.heldRowIDs.has(row.id))
    if (firstHeld < 0) firstHeld = rows.length
    for (const id of rowIDs(rows)) this.heldRowIDs.add(id)
    const fresh = rows.slice(0, firstHeld)
    const reachesBeginning = !hasOlder || rows.length === 0
    const older = this.uniqued(storedItems(fresh, new Map(), reachesBeginning))
    this.items.splice(0, 0, ...older)
    this.historyCount += older.length
    this.paging = { ...this.paging, hasOlder: hasOlder && rows.length > 0 }
    if (fresh.some((row) => row.role === 'user')) {
      this.hiddenOpening = reachesBeginning ? undefined : hiddenFirstPrompt(fresh)
    } else if (reachesBeginning && this.hiddenOpening) {
      const opening = this.hiddenOpening
      this.hiddenOpening = undefined
      const shown = this.uniqued(storedItems([opening], new Map(), true))
      const openingID = opening.id ?? Number.MAX_SAFE_INTEGER
      let position = this.items.slice(0, this.historyCount).findIndex((item) => (item.rowID ?? Number.MAX_SAFE_INTEGER) > openingID)
      if (position < 0) position = this.historyCount
      this.items.splice(position, 0, ...shown)
      this.historyCount += shown.length
    }
    const storedAfterAll = this.settleByReceipt()
    if (storedAfterAll.size > 0) this.removeLiveItems((item) => storedAfterAll.has(item.id))
  }

  // MARK: - Rebuilds

  keepError(message: string): void {
    this.lastError = message
  }

  /** Asks for a re-read of the newest rows; before the newest page is in, it waits for it. */
  requestReread(): void {
    if (this.paging.isLoaded) {
      if (this.paging.rereadable) this.needsReread = true
    } else {
      this.rereadWhenLoaded = true
    }
  }

  /** A chat shown again reports whether a turn runs now (`session.activate`). */
  reconcileRunning(running: boolean): void {
    if (running) {
      if (!this.turnActive) this.serverBusy = true
      this.refreshRunning()
      return
    }
    if (this.turnActive) this.closeTurnHere()
    this.serverBusy = false
    this.expectedStarts = new Set([...this.expectedStarts].filter((id) => this.prompts.get(id)?.state === 'sent'))
    intersect(this.queuedStarts, this.expectedStarts)
    this.releaseQueuedPrompts()
    this.refreshRunning()
  }

  /** The open turn ends here without its `message.complete`. */
  private closeTurnHere(): void {
    this.endLiveActivity()
    this.removeLiveItems((item) => item.role === 'assistant' && item.text === '' && item.reasoning === '' && item.rowID === undefined)
    this.completions += 1
    this.clock += 1
    for (const id of this.turnItemIDs) this.finishedItems.set(id, this.completions)
    this.turnItemIDs = new Set()
    this.turnActive = false
    this.turnPromptRow = undefined
    this.status = undefined
    this.isCompacting = false
  }

  /** `session.info` with `running: false`: every turn body ends with it. */
  serverReportsIdle(): void {
    this.serverBusy = false
    if (this.turnActive && !this.outputSinceWait && !this.turnShowsReasoning) this.closeTurnHere()
    if (!this.turnActive) {
      this.expectedStarts = new Set([...this.expectedStarts].filter((id) =>
        this.prompts.get(id)?.state === 'sent' || this.queuedStarts.has(id)))
      intersect(this.queuedStarts, this.expectedStarts)
    }
    this.refreshRunning()
  }

  /** `session.interrupt` succeeded: Hermes cleared its queue. */
  serverClearedQueue(sentBeforeStop: Set<string> = new Set()): void {
    subtract(this.expectedStarts, this.queuedStarts)
    this.queuedStarts = new Set()
    for (const id of sentBeforeStop) if (this.prompts.get(id)?.state === 'sent') this.queueClearedBeforeAnswer.add(id)
    this.releaseQueuedPrompts()
    this.refreshRunning()
  }

  private handOffQueuedPrompt(): void {
    const index = this.items.findIndex((item, i) => i >= this.historyCount && isQueuedPrompt(item))
    if (index < 0) return
    const [item] = this.items.splice(index, 1)
    const { outgoingStatus: _, ...rest } = item!
    this.items.push(rest)
    this.lastPromptID = rest.id
  }

  private releaseQueuedPrompts(): void {
    for (let index = this.historyCount; index < this.items.length; index += 1) {
      if (isQueuedPrompt(this.items[index]!)) this.edit(index, { outgoingStatus: undefined })
    }
  }

  private get turnShowsReasoning(): boolean {
    return this.live().some((item) => this.turnItemIDs.has(item.id) && item.reasoning !== '')
  }

  /** `isRunning` from the three facts (see HermesKit's `Transcript`). */
  private refreshRunning(): void {
    this.isRunning = this.turnActive || this.expectedStarts.size > 0 || this.serverBusy
    if (!this.isRunning) {
      this.lastSentAt = undefined
      this.buildNotice = undefined
      this.status = undefined
      this.isCompacting = false
    }
  }

  /** Starts a re-read of the newest rows: it may settle everything up to now. */
  beginReread(): RereadTicket {
    this.needsReread = false
    return { clock: this.clock, completions: this.completions, starts: this.starts }
  }

  /** `rows` up to the first one the open turn shows live (`rowsBeforeOpenTurn`). */
  private rowsBeforeOpenTurn(rows: readonly StoredMessage[]): readonly StoredMessage[] {
    const floor = Math.max(this.openTurnRowFloor, this.turnPromptRow ?? 0)
    const live = this.live().filter((item) => this.turnItemIDs.has(item.id))
    const calls = new Set(live.flatMap((item) => (item.role === 'tool' && item.toolCallID ? [item.toolCallID] : [])))
    const texts = new Set(live.flatMap((item) => (item.role === 'assistant' ? [normalizedText(item.text)] : [])).filter((t) => t !== ''))
    if (calls.size === 0 && texts.size === 0) return rows
    const shownLive = (row: StoredMessage): boolean => {
      if (typeof row.id !== 'number' || row.id <= floor || this.heldRowIDs.has(row.id)) return false
      if (row.role === 'tool') return row.tool_call_id ? calls.has(row.tool_call_id) : false
      if (row.role === 'assistant') {
        const rowCalls = asArray(row.tool_calls).flatMap((call) => (stringAt(call, 'id') !== undefined ? [stringAt(call, 'id')!] : []))
        return rowCalls.some((id) => calls.has(id)) || texts.has(normalizedText(displayText(row)))
      }
      return false
    }
    let cut = rows.findIndex(shownLive)
    if (cut < 0) return rows
    let held = -1
    rows.forEach((row, index) => { if (typeof row.id === 'number' && this.heldRowIDs.has(row.id)) held = index })
    if (held >= cut) cut = held + 1
    return rows.slice(0, cut)
  }

  /** Installs a re-read of the newest rows, then drops the live items it settles. */
  installRereadPage(allRows: readonly StoredMessage[], ticket: RereadTicket, reachesStart: boolean): void {
    const rows = this.turnActive ? this.rowsBeforeOpenTurn(allRows) : allRows
    const cut = rows.length < allRows.length
    if (!this.paging.rereadable || rows.length === 0) return
    const rereadIDs = new Set(rowIDs(rows))
    const start = this.items.slice(0, this.historyCount).findIndex((item) => item.rowID !== undefined && rereadIDs.has(item.rowID))
    if (start >= 0) {
      this.replaceHistory(start, rows, reachesStart)
      let fresh = 0
      for (const id of rereadIDs) if (!this.heldRowIDs.has(id)) fresh += 1
      this.paging = { ...this.paging, rowsLoaded: this.paging.rowsLoaded + fresh }
      for (const id of rereadIDs) this.heldRowIDs.add(id)
    } else {
      this.replaceHistory(0, rows, reachesStart)
      this.heldRowIDs = rereadIDs
      this.paging = { ...this.paging, rowsLoaded: rows.length, hasOlder: !reachesStart }
      this.hiddenOpening = reachesStart ? undefined : hiddenFirstPrompt(rows)
    }
    const installedUpTo = maxOf(rowIDs(rows)) ?? 0
    const promptRowIn = this.turnPromptRow !== undefined && this.turnPromptRow <= installedUpTo
    const settled = new Set<string>()
    for (const [id, completion] of this.finishedItems) {
      const receipt = this.receiptRowByCompletion.get(completion)
      if (completion <= ticket.completions && (!cut || promptRowIn || (receipt !== undefined && receipt <= installedUpTo))) {
        settled.add(id)
      }
    }
    for (const id of settled) this.finishedItems.delete(id)
    const unsettled = new Set(this.finishedItems.values())
    for (const key of [...this.receiptRowByCompletion.keys()]) if (!unsettled.has(key)) this.receiptRowByCompletion.delete(key)
    const quiet = !this.turnActive && !this.isCompacting && this.starts === ticket.starts
      && ![...this.prompts.values()].some((state) => state.state === 'sent')
    const eligible = new Set<string>()
    const storedAtSubmit = new Set<string>()
    if (quiet) {
      for (const [id, state] of this.prompts) {
        if (state.state !== 'answered' || state.clock > ticket.clock) continue
        if (this.rebuiltPendingPrompts.has(id) && state.storedRow !== undefined && !this.heldRowIDs.has(state.storedRow)) continue
        eligible.add(id)
        if (state.storedRow !== undefined) storedAtSubmit.add(id)
      }
    }
    const dropped = new Set([...storedAtSubmit, ...[...eligible].filter((id) => this.quietOnce.has(id))])
    this.quietOnce = new Set([...eligible].filter((id) => !dropped.has(id)))
    if (this.quietOnce.size > 0) this.needsReread = true
    this.keepSentImages(dropped)
    for (const id of dropped) this.prompts.delete(id)
    const storedAfterAll = this.settleByReceipt()
    this.removeLiveItems((item) => settled.has(item.id) || dropped.has(item.id) || storedAfterAll.has(item.id))
    const unstarted = [...dropped].filter((id) => this.queuedStarts.has(id))
    if (unstarted.length > 0) {
      subtract(this.expectedStarts, unstarted)
      subtract(this.queuedStarts, unstarted)
      this.refreshRunning()
    }
    this.dropPromptsShownByRows()
  }

  /** Drops prompt bubbles whose own stored row (`user_row_id`) the history now shows. */
  private dropPromptsShownByRows(): void {
    const shown = new Set(this.items.slice(0, this.historyCount).flatMap((item) => (item.rowID !== undefined ? [item.rowID] : [])))
    const proven = new Set<string>()
    for (const [id, state] of this.prompts) {
      if (state.state === 'answered' && state.storedRow !== undefined && shown.has(state.storedRow)) proven.add(id)
    }
    if (proven.size === 0) return
    this.keepSentImages(proven)
    subtract(this.rebuiltPendingPrompts, proven)
    for (const id of proven) this.prompts.delete(id)
    subtract(this.quietOnce, proven)
    this.removeLiveItems((item) => proven.has(item.id))
  }

  private keepSentImages(ids: Set<string>): void {
    for (const bubble of this.live()) {
      if (!ids.has(bubble.id) || bubble.images.length === 0) continue
      const state = this.prompts.get(bubble.id)
      if (state?.state !== 'answered' || state.storedRow === undefined) continue
      const row = state.storedRow
      this.sentImages.set(row, bubble.images)
      for (let index = 0; index < this.historyCount; index += 1) {
        const item = this.items[index]!
        if (item.role === 'user' && item.rowID === row && item.images.length === 0) this.edit(index, { images: bubble.images })
      }
    }
  }

  private withSentImages(item: TranscriptItem): TranscriptItem {
    if (item.role !== 'user' || item.rowID === undefined) return item
    const images = this.sentImages.get(item.rowID)
    if (!images) return item
    if (item.images.length > 0) {
      this.sentImages.delete(item.rowID)
      return item
    }
    return { ...item, images }
  }

  /** Takes over the unresolved local prompts owned by this chat's sends (`ChatSession.reset`). */
  adoptPendingPrompts(old: Transcript, ids: Set<string>): void {
    for (const item of old.items) {
      if (!ids.has(item.id) || old.prompts.get(item.id)?.state !== 'sent') continue
      if (this.items.some((candidate) => candidate.id === item.id)) continue
      this.items.push(item)
      this.prompts.set(item.id, { state: 'sent' })
      this.rebuiltPendingPrompts.add(item.id)
      this.promptSentAtStarts.set(item.id, this.starts)
      this.expectedStarts.add(item.id)
    }
    this.refreshRunning()
  }

  updatePromptImages(images: readonly TranscriptImage[], itemID: string): void {
    const index = this.items.findIndex((item) => item.id === itemID)
    if (index >= 0) this.edit(index, { images })
  }

  /** Takes over the images of prompts the replaced transcript sent. */
  adoptSentImages(old: Transcript): void {
    for (const [row, images] of old.sentImages) if (!this.sentImages.has(row)) this.sentImages.set(row, images)
    if (this.sentImages.size === 0) return
    for (let index = 0; index < this.historyCount; index += 1) this.items[index] = this.withSentImages(this.items[index]!)
  }

  /** Projects `rows` into the history from `start` on; local rows there go back after their anchors. */
  private replaceHistory(start: number, rows: readonly StoredMessage[], startsSession: boolean): void {
    const toolCalls: ToolCalls = new Map()
    let stored = storedItems(rows, toolCalls, startsSession)
    if (this.sentImages.size > 0) stored = stored.map((item) => this.withSentImages(item))
    const locals = this.items.slice(start, this.historyCount).filter((item) => this.localIDs.has(item.id))
    this.items.splice(start, this.historyCount - start)
    this.historyCount = start
    const unique = this.uniqued(stored)
    this.items.splice(start, 0, ...unique)
    this.historyCount += unique.length
    for (const local of locals) this.placeLocalRow(local)
  }

  // MARK: - Local rows

  private appendLocal(item: TranscriptItem): void {
    this.sealActiveAssistant()
    this.lateTail = undefined
    this.items.push(item)
    this.localIDs.add(item.id)
    this.absorbLocalRows()
  }

  private absorbLocalRows(): void {
    this.placeAnchoredLocalRows()
    if (!this.paging.isLoaded || this.turnActive) return
    while (this.historyCount < this.items.length && this.localIDs.has(this.items[this.historyCount]!.id)) {
      const id = this.items[this.historyCount]!.id
      const anchor = this.items.slice(0, this.historyCount).reverse().find((item) => item.rowID !== undefined)?.rowID
      if (anchor !== undefined) this.localAnchors.set(id, anchor)
      else this.localAnchors.delete(id)
      this.historyCount += 1
    }
  }

  private placeAnchoredLocalRows(): void {
    const shown = new Set(this.items.slice(0, this.historyCount).flatMap((item) => (item.rowID !== undefined ? [item.rowID] : [])))
    const ready = this.live().filter((item) => {
      const anchor = this.localAnchors.get(item.id)
      return this.localIDs.has(item.id) && anchor !== undefined && shown.has(anchor)
    })
    if (ready.length === 0) return
    const ids = new Set(ready.map((item) => item.id))
    const live = this.live().filter((item) => !ids.has(item.id))
    this.items.splice(this.historyCount)
    this.items.push(...live)
    for (const item of ready) this.placeLocalRow(item)
  }

  private placeLocalRow(item: TranscriptItem): void {
    let position = 0
    const anchor = this.localAnchors.get(item.id)
    if (anchor !== undefined) {
      for (let index = this.historyCount - 1; index >= 0; index -= 1) {
        const rowID = this.items[index]!.rowID
        if (rowID !== undefined && rowID <= anchor) { position = index + 1; break }
      }
    }
    while (position < this.historyCount && this.localIDs.has(this.items[position]!.id)) position += 1
    this.items.splice(position, 0, item)
    this.historyCount += 1
  }

  /** Ids stay unique: a page that repeats a row gives the repeat a suffix. */
  private uniqued(stored: readonly TranscriptItem[]): TranscriptItem[] {
    const seen = new Set(this.items.map((item) => item.id))
    return stored.map((original) => {
      let id = original.id
      let suffix = 0
      while (seen.has(id)) {
        suffix += 1
        id = `${original.id}~${suffix}`
      }
      seen.add(id)
      return id === original.id ? original : { ...original, id }
    })
  }

  private removeLiveItems(shouldRemove: (item: TranscriptItem) => boolean): void {
    const live = this.live().filter((item) => !shouldRemove(item))
    this.items.splice(this.historyCount)
    this.items.push(...live)
    this.absorbLocalRows()
  }

  // MARK: - Prompts sent here

  /**
   * Shows the user's prompt at once; call before `prompt.submit`, then `promptAnswered`
   * or `submitFailed`. Returns the item's id. The reply streaming so far is sealed.
   */
  appendUserPrompt(text: string, options: {
    images?: readonly TranscriptImage[]; attachments?: readonly string[]; attachmentPaths?: readonly string[]
    displayKind?: string; sentAt?: number
  } = {}): string {
    const streaming = this.activeAssistantIndex
    const streamingID = streaming !== undefined ? this.items[streaming]!.id : undefined
    this.sealActiveAssistant()
    this.counter += 1
    const sentAt = options.sentAt ?? Date.now()
    const item: TranscriptItem = {
      ...makeItem(`local-${this.counter}`, 'user', text),
      outgoingStatus: 'Sending…',
      images: options.images ?? [],
      attachments: options.attachments ?? [],
      attachmentPaths: options.attachmentPaths ?? [],
      ...(options.displayKind ? { displayKind: options.displayKind } : {}),
      timestamp: sentAt,
    }
    if (streamingID) this.lateTail = { itemID: streamingID, promptID: item.id, keepsRound: options.displayKind === 'steer' }
    this.items.push(item)
    this.prompts.set(item.id, { state: 'sent' })
    this.promptSentAtStarts.set(item.id, this.starts)
    this.expectedStarts.add(item.id)
    this.lastSentAt = sentAt
    this.lastPromptID = item.id
    this.outputSinceWait = false
    this.lastError = undefined
    this.refreshRunning()
    return item.id
  }

  /** Takes back a prompt bubble the gateway never took. */
  withdrawPrompt(itemID: string): void {
    if (!this.prompts.delete(itemID)) return
    this.rebuiltPendingPrompts.delete(itemID)
    this.promptSentAtStarts.delete(itemID)
    this.expectedStarts.delete(itemID)
    this.queuedStarts.delete(itemID)
    this.queueClearedBeforeAnswer.delete(itemID)
    this.removeLiveItems((item) => item.id === itemID)
    this.refreshRunning()
  }

  /** Moves a prompt bubble to the end: a redirect the gateway queued as the next turn. */
  movePromptToEnd(itemID: string): void {
    if (!this.prompts.has(itemID)) return
    const index = this.lastLiveIndex((item) => item.id === itemID)
    if (index === undefined) return
    const [item] = this.items.splice(index, 1)
    this.items.push(item!)
  }

  /** A local system line (slash-command output, notices). Never stored. */
  appendNote(text: string, displayKind?: string): void {
    this.appendLocal({ ...makeItem(this.nextID(), 'system', text), ...(displayKind ? { displayKind } : {}) })
  }

  /** Shows a `/btw` question or `/bg` task until its answer arrives. */
  beginSideQuestion(taskID: string, question: string, kind: SideQuestion['kind'] = 'btw'): void {
    const id = sideQuestionItemID(taskID, kind)
    const index = this.lastIndex((item) => item.id === id)
    if (index !== undefined) {
      const side = this.items[index]!.sideQuestion
      if (side && side.question === undefined) this.edit(index, { sideQuestion: { ...side, question } })
      return
    }
    this.appendLocal({ ...makeItem(id, 'system', ''), sideQuestion: { taskID, question, kind } })
  }

  /** `prompt.submit` answered, whatever its `status`. */
  promptAnswered(itemID: string, status?: string, userRowID?: number): void {
    if (!this.prompts.has(itemID)) return
    const queueCleared = this.queueClearedBeforeAnswer.delete(itemID)
    const waits = status === 'queued' && !queueCleared && this.expectedStarts.has(itemID)
    const index = this.items.findIndex((item) => item.id === itemID)
    if (index >= 0) this.edit(index, { outgoingStatus: waits ? queuedStatus : undefined })
    try {
      if ((status === 'steered' || status === 'queued') && this.lateTail?.promptID === itemID) this.lateTail.keepsRound = true
      switch (status) {
        case 'steered': case 'redirected':
          this.expectedStarts.delete(itemID)
          this.queuedStarts.delete(itemID)
          break
        case 'queued':
          if (queueCleared) this.expectedStarts.delete(itemID)
          else if (this.expectedStarts.has(itemID)) this.queuedStarts.add(itemID)
          break
        case 'streaming':
          if (this.turnActive && !this.expectedStarts.has(itemID) && userRowID !== undefined) this.turnPromptRow = userRowID
          break
        default:
          break
      }
      if (status === 'streaming' && userRowID === undefined) {
        this.prompts.delete(itemID)
        const sentAt = this.promptSentAtStarts.get(itemID) ?? this.starts
        this.promptSentAtStarts.delete(itemID)
        if (this.turnActive && this.starts > sentAt) this.turnItemIDs.add(itemID)
        else this.awaitingTurn.add(itemID)
        return
      }
      this.promptSentAtStarts.delete(itemID)
      this.clock += 1
      this.prompts.set(itemID, {
        state: 'answered', clock: this.clock,
        ...(status === 'streaming' && userRowID !== undefined ? { storedRow: userRowID } : {}),
      })
      this.dropPromptsShownByRows()
      if (!this.turnActive && !(waits && this.isCompacting) && this.paging.rereadable) this.needsReread = true
    } finally {
      this.refreshRunning()
    }
  }

  /** Marks a failed submit: the bubble stays (only it holds the text). */
  submitFailed(message: string, itemID?: string, dispatched = true): void {
    this.lastError = message
    if (itemID !== undefined && this.prompts.has(itemID)) {
      this.prompts.set(itemID, { state: 'failed' })
      const index = this.items.findIndex((item) => item.id === itemID)
      if (index >= 0) this.edit(index, { outgoingStatus: (dispatched ? 'Not confirmed · ' : 'Not sent · ') + message })
      this.promptSentAtStarts.delete(itemID)
      this.expectedStarts.delete(itemID)
      this.queuedStarts.delete(itemID)
      this.queueClearedBeforeAnswer.delete(itemID)
    }
    this.refreshRunning()
  }

  addRequest(request: ServerRequest): void {
    if (this.pendingRequests.some((existing) => existing.id === request.id)) return
    this.pendingRequests = [...this.pendingRequests, request]
  }

  removeRequest(id: string): void {
    if (!this.pendingRequests.some((request) => request.id === id)) return
    this.pendingRequests = this.pendingRequests.filter((request) => request.id !== id)
  }

  // MARK: - Events

  apply(event: GatewayEvent): void {
    const kind = eventKind(event)
    if (providerWaitSuperseding.has(event.type)) this.providerWait = undefined
    if (draftSuperseding.has(event.type)) this.generatingTool = undefined
    if (this.isCompacting && showsTheTurnMovedOn(kind.kind)) this.isCompacting = false
    if (endsLateTail(kind.kind)) this.lateTail = undefined
    try {
      this.applyKind(kind, event)
    } finally {
      if (this.readsPromptAtFirstOutput && (this.outputSinceWait || !this.turnActive)) {
        this.readsPromptAtFirstOutput = false
        if (this.turnActive) this.requestReread()
      }
    }
  }

  private applyKind(kind: GatewayEventKind, event: GatewayEvent): void {
    switch (kind.kind) {
      case 'messageStart':
        this.startTurn(true)
        if (this.activeAssistantIndex === undefined) this.append('assistant', '', true)
        return
      case 'messageDelta': {
        this.startTurn()
        const index = this.lateTailIndex(kind.delta.text) ?? this.activeAssistantIndex ?? this.append('assistant', '', true)
        this.edit(index, { text: this.items[index]!.text + kind.delta.text })
        if (isVisibleOutput(this.items[index]!)) this.outputSinceWait = true
        return
      }
      case 'reasoningDelta': {
        this.startTurn()
        const index = this.activeAssistantIndex ?? this.append('assistant', '', true)
        this.edit(index, { reasoning: this.items[index]!.reasoning + kind.delta.text })
        return
      }
      case 'reasoningAvailable': {
        this.startTurn()
        if (this.roundShowsText) return
        const index = this.activeAssistantIndex ?? this.append('assistant', '', true)
        if (kind.delta.text !== '' && this.items[index]!.text.trim() === '') this.edit(index, { reasoning: kind.delta.text })
        return
      }
      case 'thinkingDelta':
        this.startTurn()
        this.providerWait = providerWaitText(kind.delta.text)
        return
      case 'messageInterim': {
        this.startTurn()
        const text = kind.interim.text.trim()
        if (text !== '') this.outputSinceWait = true
        if (text === '') {
          const index = this.activeAssistantIndex
          if (kind.interim.already_streamed === true && index !== undefined) this.edit(index, { isActive: false })
        } else {
          this.sealRound(text)
        }
        return
      }
      case 'toolGenerating':
        this.startTurn()
        this.sealActiveAssistant()
        this.generatingTool = kind.generating.name
        return
      case 'toolStart': {
        const start = kind.start
        this.startTurn()
        this.sealActiveAssistant()
        this.generatingTool = undefined
        let index = this.runningToolIndex(start.tool_id)
        if (index !== undefined) {
          this.edit(index, { isActive: true })
        } else {
          this.appendLive({ ...makeItem(toolItemID(start.tool_id), 'tool', '', true), toolCallID: start.tool_id })
          index = this.items.length - 1
        }
        const tool: ToolActivity = { ...(this.items[index]!.tool ?? { toolID: start.tool_id, name: start.name, phase: 'running' }) }
        tool.phase = 'running'
        const context = start.context ?? start.preview ?? tool.context
        if (context !== undefined) tool.context = context
        if (start.args !== undefined) tool.args = start.args
        this.edit(index, { tool, toolName: start.name, detail: tool.context })
        this.outputSinceWait = true
        return
      }
      case 'toolComplete': {
        const complete = kind.complete
        this.startTurn()
        this.generatingTool = undefined
        let index = this.runningToolIndex(complete.tool_id)
        if (index === undefined) {
          this.sealActiveAssistant()
          this.appendLive({ ...makeItem(toolItemID(complete.tool_id), 'tool', ''), toolCallID: complete.tool_id })
          index = this.items.length - 1
        }
        const tool: ToolActivity = { ...(this.items[index]!.tool ?? { toolID: complete.tool_id, name: complete.name, phase: 'running' }) }
        const error = complete.error ? complete.error : undefined
        tool.phase = error === undefined ? 'complete' : 'failed'
        if (error !== undefined) tool.error = error
        else delete tool.error
        if (complete.args !== undefined) tool.args = complete.args
        if (complete.summary !== undefined) tool.summary = complete.summary
        else delete tool.summary
        const output = complete.result_text ?? resultText(complete.result) ?? tool.output
        if (output !== undefined) tool.output = output
        if (complete.result !== undefined) tool.result = complete.result
        if (complete.inline_diff !== undefined) tool.inlineDiff = complete.inline_diff
        else delete tool.inlineDiff
        if (complete.duration_s !== undefined) tool.durationSeconds = complete.duration_s
        else delete tool.durationSeconds
        const change: Partial<TranscriptItem> = { tool, isActive: false, toolName: complete.name }
        if (complete.summary) (change as { detail?: string }).detail = complete.summary
        this.edit(index, change)
        this.outputSinceWait = true
        return
      }
      case 'messageComplete':
        this.finishTurn(kind.complete)
        return
      case 'statusUpdate': {
        const update = kind.update
        if (isMemoryRecallIndicator(update)) return
        const compacting = compactionEdge(update)
        if (compacting !== undefined) {
          this.isCompacting = compacting
          this.status = undefined
          return
        }
        this.status = update.text === '' ? undefined : update.text
        return
      }
      case 'btwComplete':
        this.completeSideAgent(kind.answer, 'btw')
        return
      case 'backgroundComplete':
        this.completeSideAgent(kind.answer, 'background')
        return
      case 'reviewSummary':
        this.appendReviewNote(kind.summary.text, event.seq)
        return
      case 'error':
        this.lastError = kind.message
        this.isCompacting = false
        if (this.turnActive && !this.outputSinceWait && !this.turnShowsReasoning) this.closeTurnHere()
        if (!this.turnActive) {
          this.serverBusy = false
          this.expectedStarts = new Set([...this.expectedStarts].filter((id) => this.prompts.get(id)?.state === 'sent'))
          intersect(this.queuedStarts, this.expectedStarts)
          this.refreshRunning()
        }
        return
      case 'requestCancel':
        this.removeRequest(kind.cancel.id)
        return
      case 'approvalCancelled': {
        const ids = new Set(kind.cancelled.request_ids)
        const kept = this.pendingRequests.filter((request) => {
          const typed = requestKind(request)
          return !(typed.kind === 'approval' && ids.has(typed.approval.request_id))
        })
        if (kept.length !== this.pendingRequests.length) this.pendingRequests = kept
        return
      }
      case 'notificationShow':
        if (kind.notice.key === buildNoticeKey) this.buildNotice = kind.notice.text
        return
      case 'notificationClear':
        if (kind.key === buildNoticeKey) this.buildNotice = undefined
        return
      default:
        return
    }
  }

  // MARK: - Helpers

  private completeSideAgent(answer: SideAgentComplete, kind: SideQuestion['kind']): void {
    const id = sideQuestionItemID(answer.task_id, kind)
    const index = this.lastIndex((item) => item.id === id)
    if (index !== undefined) {
      const side = this.items[index]!.sideQuestion
      const next: SideQuestion | undefined = side
        ? { ...side, answer: answer.text, ...(answer.question !== undefined ? { question: answer.question } : {}) }
        : undefined
      this.edit(index, { text: answer.text, ...(next ? { sideQuestion: next } : {}) })
    } else {
      const sideQuestion: SideQuestion = { taskID: answer.task_id, answer: answer.text, kind }
      if (answer.question !== undefined) sideQuestion.question = answer.question
      this.appendLocal({ ...makeItem(id, 'system', answer.text), sideQuestion })
    }
  }

  private appendReviewNote(text: string, seq: number | undefined): void {
    const trimmed = text.trim()
    if (trimmed === '') return
    const id = 'review-' + (seq !== undefined ? String(seq) : this.nextID())
    if (this.items.some((item) => item.id === id)) return
    this.appendLocal({ ...makeItem(id, 'system', trimmed), displayKind: reviewDisplayKind })
  }

  private liveAssistantSinceUser(text: string): number | undefined {
    const target = normalizedText(text)
    for (let index = this.items.length - 1; index >= this.historyCount; index -= 1) {
      const item = this.items[index]!
      if (item.role === 'user' && !isSteer(item)) return undefined
      if (item.role === 'assistant' && normalizedText(item.text) === target) return index
    }
    return undefined
  }

  /** The open turn's current round: its live assistant items since the round began. */
  private get currentRound(): number[] {
    const turn: number[] = []
    for (let index = this.historyCount; index < this.items.length; index += 1) {
      const item = this.items[index]!
      if (this.turnItemIDs.has(item.id) && !this.localIDs.has(item.id)) turn.push(index)
    }
    const lastTool = [...turn].reverse().find((index) => this.items[index]!.role === 'tool')
    const boundary = lastTool ?? [...turn].reverse().find((index) => this.items[index]!.role === 'assistant' && this.items[index]!.isInterim)
    const floor = boundary ?? this.historyCount - 1
    return turn.filter((index) => index > floor && this.items[index]!.role === 'assistant')
  }

  private get roundShowsText(): boolean {
    return this.currentRound.some((index) => this.items[index]!.text.trim() !== '')
  }

  /** `message.interim`: the current round's call ended with `text` visible (`sealRound`). */
  private sealRound(text: string): void {
    const target = normalizedText(text)
    const open = this.currentRound.filter((index) => !this.items[index]!.isInterim)
    const segments = open.filter((index) => normalizedText(this.items[index]!.text) !== '')
    const joined = normalizedText(segments.map((index) => this.items[index]!.text).join(' '))
    for (const index of open) this.edit(index, { isActive: false })
    const seal = (index: number) => this.edit(index, { text, isActive: false, isInterim: true })
    const match = [...segments].reverse().find((index) => normalizedText(this.items[index]!.text) === target)
    if (match !== undefined) {
      seal(match)
      return
    }
    const first = segments[0]
    if (first !== undefined && target.startsWith(joined)) {
      seal(first)
      const emptied = segments.slice(1)
      for (const index of emptied) this.edit(index, { text: '' })
      const gone = new Set(emptied.filter((index) => this.items[index]!.reasoning === '').map((index) => this.items[index]!.id))
      this.items = this.items.filter((item) => !gone.has(item.id))
      subtract(this.turnItemIDs, gone)
      return
    }
    const repeated = this.liveAssistantSinceUser(text)
    if (repeated !== undefined && this.items[repeated]!.isInterim) {
      this.edit(repeated, { text })
      return
    }
    if (segments.length === 0) {
      const index = this.activeAssistantIndex ?? [...open].reverse().find((i) => this.items[i]!.reasoning !== '')
      if (index !== undefined) {
        seal(index)
        return
      }
    }
    seal(this.append('assistant', text))
  }

  /** A user row: recalled memory out, `@image:` lines and hints as images, leading `@file:` lines as attachments. */
  private appendUser(text: string, rowID?: number): number {
    const turn = userTurn(text)
    const { caption, paths: directives } = splitImageDirectives(turn.text)
    const { text: body, refs } = splitLeadingAttachmentRefs(caption)
    const index = this.append('user', body, false, rowID)
    this.edit(index, {
      images: storedImages([...directives, ...turn.imagePaths]),
      attachments: refs.map(attachmentDisplayName),
      attachmentPaths: refs,
    })
    return index
  }

  private endLiveActivity(): void {
    for (let index = this.historyCount; index < this.items.length; index += 1) {
      const item = this.items[index]!
      if (item.isActive || item.tool?.phase === 'running') {
        this.edit(index, { isActive: false, ...(item.tool?.phase === 'running' ? { tool: { ...item.tool, phase: 'complete' as const } } : {}) })
      }
    }
    this.generatingTool = undefined
  }

  /** A turn's first event starts it (`message.start`, or any streamed event of a turn this chat saw no start of). */
  private startTurn(announced = false): void {
    if (this.turnActive) return
    if (!this.serverBusy) this.handOffQueuedPrompt()
    this.readsPromptAtFirstOutput = announced && this.expectedStarts.size === 0 && !this.serverBusy
    if (this.readsPromptAtFirstOutput) this.requestReread()
    this.turnActive = true
    this.openTurnRowFloor = Math.max(maxOf(this.heldRowIDs) ?? 0, this.newestReceiptRow)
    this.starts += 1
    this.clock += 1
    this.quietOnce = new Set()
    this.turnPromptRow = maxOf([...this.expectedStarts].flatMap((id) => {
      const state = this.prompts.get(id)
      return state?.state === 'answered' && state.storedRow !== undefined ? [state.storedRow] : []
    }))
    this.expectedStarts = new Set()
    this.queuedStarts = new Set()
    this.serverBusy = false
    this.outputSinceWait = false
    this.refreshRunning()
    for (const id of this.awaitingTurn) this.turnItemIDs.add(id)
    this.awaitingTurn = new Set()
  }

  private runningToolIndex(toolID: string): number | undefined {
    return this.lastLiveIndex((item) => item.isActive && item.toolCallID === toolID)
  }

  private get activeAssistantIndex(): number | undefined {
    const last = this.items.length - 1
    if (last < 0 || last < this.historyCount) return undefined
    const item = this.items[last]!
    return item.role === 'assistant' && item.isActive ? last : undefined
  }

  private lateTailIndex(text: string): number | undefined {
    const tail = this.lateTail
    if (!tail) return undefined
    const index = this.lastLiveIndex((item) => item.id === tail.itemID)
    if (this.activeAssistantIndex !== undefined || !(tail.keepsRound || !text.startsWith('\n\n')) || index === undefined) {
      this.lateTail = undefined
      return undefined
    }
    return index
  }

  private sealActiveAssistant(): void {
    const index = this.activeAssistantIndex
    if (index === undefined) return
    const item = this.items[index]!
    if (item.text === '' && item.reasoning === '') this.items.splice(index, 1)
    else this.edit(index, { isActive: false })
  }

  private finishTurn(complete: MessageComplete): void {
    this.startTurn()
    const persistedRowIDs = complete.persisted_turn?.row_ids
    const persistedUserRowID = complete.persisted_turn?.user_row_id
    const receipt = [...(persistedRowIDs ?? []), ...(persistedUserRowID !== undefined ? [persistedUserRowID] : [])]
    this.newestReceiptRow = Math.max(this.newestReceiptRow, maxOf(receipt) ?? 0)
    const finalText = completeText(complete)
    const active = this.activeAssistantIndex
    let streaming = active !== undefined ? this.items[active]!.id : undefined
    let stoppedMark: string | undefined
    if (active !== undefined) {
      const item = this.items[active]!
      const change: Partial<{ -readonly [K in keyof TranscriptItem]: TranscriptItem[K] }> = { outcome: complete.status }
      if (item.text === '' && finalText !== '' && !this.turnShows(finalText)) change.text = finalText
      if (item.reasoning === '' && complete.reasoning !== undefined) change.reasoning = complete.reasoning
      this.edit(active, change)
      if (complete.status === 'interrupted' && this.items[active]!.text === '') stoppedMark = item.id
    } else if (finalText !== '' && !this.turnShows(finalText)) {
      const index = this.append('assistant', finalText)
      this.edit(index, { outcome: complete.status })
      streaming = this.items[index]!.id
    } else {
      const last = this.items.length - 1
      if (last >= this.historyCount && last >= 0 && this.items[last]!.role === 'assistant') this.edit(last, { outcome: complete.status })
    }
    this.endLiveActivity()
    if (stoppedMark !== undefined) {
      this.turnItemIDs.delete(stoppedMark)
      this.localIDs.add(stoppedMark)
      const anchor = maxOf(persistedRowIDs ?? []) ?? persistedUserRowID ?? this.turnPromptRow
      if (anchor !== undefined) this.localAnchors.set(stoppedMark, anchor)
    }
    this.removeLiveItems((item) => item.role === 'assistant' && item.text === '' && item.reasoning === ''
      && item.rowID === undefined && item.id !== stoppedMark)
    if (complete.status === 'error') this.lastError = complete.error ?? 'The turn failed.'
    this.status = undefined
    this.isCompacting = false

    this.completions += 1
    this.clock += 1
    const newest = maxOf(receipt)
    if (newest !== undefined) this.receiptRowByCompletion.set(this.completions, newest)
    let unstored: string | undefined
    const unstoredSplit = new Set<string>()
    switch (complete.status) {
      case 'error':
        unstored = streaming
        for (const index of this.currentRound) if (this.items[index]!.rowID === undefined) unstoredSplit.add(this.items[index]!.id)
        break
      case 'interrupted': {
        const sent = finalText.trim()
        const shownItem = streaming !== undefined ? this.items.find((item) => item.id === streaming) : undefined
        const shown = shownItem?.text.trim()
        const sameReply = shown !== undefined && (shown === sent
          || (sent !== '' && shown.endsWith(sent))
          || (sent !== '' && shown !== '' && sent.endsWith(shown)))
        unstored = sent === repetitionLoopSentinel || sameReply ? undefined : streaming
        break
      }
      default:
        unstored = undefined
    }
    for (const id of this.turnItemIDs) if (id !== unstored && !unstoredSplit.has(id)) this.finishedItems.set(id, this.completions)
    if (complete.status === 'error' && persistedRowIDs && persistedRowIDs.length > 0) {
      for (const id of unstoredSplit) this.unstoredByReceipt.set(id, new Set(persistedRowIDs))
    }
    this.turnItemIDs = new Set()
    this.turnActive = false
    this.turnPromptRow = undefined
    this.refreshRunning()
    if (this.paging.rereadable) this.needsReread = true
  }

  /** Whether the turn streaming now already shows `text`. */
  private turnShows(text: string): boolean {
    const trimmed = text.trim()
    const own = this.items.filter((item) => this.turnItemIDs.has(item.id) && item.role === 'assistant')
    if (own.some((item) => item.text.trim() === trimmed)) return true
    const target = normalizedText(trimmed)
    if (target === '') return false
    const texts = own.map((item) => item.text)
    return normalizedText(texts.join('')).endsWith(target) || normalizedText(texts.join(' ')).endsWith(target)
  }

  /** The items an `error` end left unstored that the history now shows stored. */
  private settleByReceipt(): Set<string> {
    if (this.unstoredByReceipt.size === 0) return new Set()
    const stored = this.items.slice(0, this.historyCount).filter((item) => item.role === 'assistant')
    const settled = new Set<string>()
    for (const [id, receipt] of [...this.unstoredByReceipt]) {
      const item = this.live().find((candidate) => candidate.id === id)
      if (!item) {
        this.unstoredByReceipt.delete(id)
        continue
      }
      const text = squeezed(item.text)
      if (text !== '' && stored.some((row) => row.rowID !== undefined && receipt.has(row.rowID) && squeezed(row.text) === text)) {
        settled.add(id)
        this.unstoredByReceipt.delete(id)
      } else if ([...receipt].every((row) => this.heldRowIDs.has(row))) {
        this.unstoredByReceipt.delete(id)
      }
    }
    return settled
  }

  private nextID(): string {
    this.counter += 1
    return `local-${this.counter}`
  }

  private append(role: TranscriptRole, text: string, active = false, rowID?: number): number {
    this.appendLive({ ...makeItem(this.nextID(), role, text, active), ...(rowID !== undefined ? { rowID } : {}) })
    return this.items.length - 1
  }

  /** Appends to the turn streaming now (`buildingHistory`: to the history). */
  private appendLive(item: TranscriptItem): void {
    let next = item
    if (this.items.some((existing) => existing.id === next.id)) {
      this.counter += 1
      next = { ...next, id: `${next.id}~${this.counter}` }
    }
    this.items.push(next)
    if (!this.buildingHistory) this.turnItemIDs.add(next.id)
  }

  /** Replaces the row at `index` with a changed copy (rows are immutable). */
  private edit(index: number, change: Partial<TranscriptItem>): void {
    const item = this.items[index]!
    const next = { ...item } as Record<string, unknown>
    for (const [key, value] of Object.entries(change)) {
      if (value === undefined) delete next[key]
      else next[key] = value
    }
    this.items[index] = next as unknown as TranscriptItem
  }

  private live(): TranscriptItem[] {
    return this.items.slice(this.historyCount)
  }

  private lastLiveIndex(match: (item: TranscriptItem) => boolean): number | undefined {
    for (let index = this.items.length - 1; index >= this.historyCount; index -= 1) if (match(this.items[index]!)) return index
    return undefined
  }

  private lastIndex(match: (item: TranscriptItem) => boolean): number | undefined {
    for (let index = this.items.length - 1; index >= 0; index -= 1) if (match(this.items[index]!)) return index
    return undefined
  }
}

function rowIDs(rows: readonly StoredMessage[]): number[] {
  return rows.flatMap((row) => (typeof row.id === 'number' ? [row.id] : []))
}

function hiddenFirstPrompt(rows: readonly StoredMessage[]): StoredMessage | undefined {
  const first = rows.find((row) => row.role === 'user')
  return first?.display_kind === 'hidden' ? first : undefined
}
