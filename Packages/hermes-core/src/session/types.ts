import type { GatewayEvent } from '../client.ts'
import type { JSONValue } from '../protocol/jsonrpc.ts'

// Payload shapes of the chat layer, as HermesKit decodes them (`GatewayEvents.swift`,
// `GatewayModels.swift`, `SessionMessages.swift`, `ServerRequests.swift`). Field names are
// the wire's; everything Hermes may leave out is optional.

/** A row of the durable display transcript (`TranscriptMessage`, contracts/common.py). */
export interface TranscriptMessage {
  role: string
  text?: string | null
  content?: JSONValue
  tool_call_id?: string | null
  timestamp?: number | null
  row_id?: number | null
  display_kind?: string | null
  name?: string | null
  context?: string | null
  args?: JSONValue
  reasoning?: string | null
}

/** Live session metadata (`SessionLiveInfo`). Subset. */
export interface SessionLiveInfo {
  model?: string | null
  provider?: string | null
  reasoning_effort?: string | null
  cwd?: string | null
  branch?: string | null
  running?: boolean | null
  title?: string | null
  stored_session_id?: string | null
  version?: string | null
  approval_mode?: string | null
  profile_name?: string | null
  usage?: JSONValue
}

/** The turn that was running when a client (re)attached (`InflightTurn`). */
export interface InflightTurn {
  assistant?: string | null
  streaming?: boolean | null
  user?: string | null
  /** Set on a retained *failed* turn (`session_auto_continue.py:546-549`). */
  error?: string | null
  status?: string | null
  recoverable?: boolean | null
}

export function inflightIsFailed(inflight: InflightTurn): boolean {
  return (inflight.error ?? '') !== ''
}

/** An unanswered server→client request returned on (re)attach (`OpenRequestEntry`). */
export interface OpenRequestEntry {
  id: string
  method: string
  params: JSONValue
}

/** Result of `session.resume` / `session.activate` / `session.create` (`LiveSessionSnapshot`). */
export interface LiveSessionSnapshot {
  session_id: string
  message_count?: number | null
  messages?: TranscriptMessage[] | null
  info?: SessionLiveInfo | null
  /** Only `session.create` fills it; resume/activate carry `session_key` (`storedKey`). */
  stored_session_id?: string | null
  session_key?: string | null
  resumed?: string | null
  running?: boolean | null
  status?: string | null
  inflight?: InflightTurn | null
  open_requests?: OpenRequestEntry[] | null
  hydrating?: boolean | null
  messages_omitted?: boolean | null
}

/** The durable key from whichever field the payload carries (HermesKit's `storedKey`). */
export function storedKey(snapshot: LiveSessionSnapshot): string | undefined {
  for (const candidate of [snapshot.session_key, snapshot.stored_session_id, snapshot.info?.stored_session_id]) {
    if (candidate) return candidate
  }
  return undefined
}

/** `session.create`'s answer as a snapshot (HermesKit's `SessionCreateResult.snapshot`). */
export interface SessionCreateResult {
  session_id: string
  stored_session_id: string
  message_count?: number
  messages?: TranscriptMessage[]
  info?: SessionLiveInfo | null
}

export function createdSnapshot(created: SessionCreateResult): LiveSessionSnapshot {
  return {
    session_id: created.session_id,
    messages: created.messages ?? [],
    message_count: (created.messages ?? []).length,
    info: created.info ?? null,
    stored_session_id: created.stored_session_id,
    running: false,
  }
}

/** One stored row of `GET /api/sessions/{id}/messages` (`StoredMessage`). */
export interface StoredMessage {
  id?: number | null
  role: string
  content?: JSONValue
  tool_call_id?: string | null
  tool_calls?: JSONValue
  tool_name?: string | null
  timestamp?: number | null
  reasoning?: string | null
  reasoning_content?: string | null
  display_kind?: string | null
  display_content?: JSONValue
}

export interface SessionMessagesPagination {
  limit?: number | null
  offset?: number | null
  order?: string | null
  returned?: number | null
}

export interface SessionMessagesPage {
  session_id?: string | null
  profile?: string | null
  messages: StoredMessage[]
  /** Missing on gateways that predate paging: the page is then the whole history. */
  pagination?: SessionMessagesPagination | null
}

export interface SessionMessagesQuery {
  sessionID: string
  profile?: string
  order?: 'latest' | 'oldest'
  limit: number
  offset?: number
}

/** REST reads of stored transcripts (HermesKit's `SessionMessagesSource`). */
export interface SessionMessagesSource {
  messagesPage(query: SessionMessagesQuery): Promise<SessionMessagesPage>
}

// MARK: - Server requests

export type ApprovalChoice = 'once' | 'session' | 'always' | 'deny'

export interface ApprovalRequest {
  session_id: string
  request_id: string
  command?: string | null
  description?: string | null
  choices?: ApprovalChoice[] | null
  allow_permanent?: boolean | null
  allow_session?: boolean | null
  tool_name?: string | null
}

/** Choices to offer, honouring the allow flags when `choices` is absent. */
export function offeredApprovalChoices(request: ApprovalRequest): ApprovalChoice[] {
  if (request.choices && request.choices.length > 0) return request.choices
  const result: ApprovalChoice[] = ['once']
  if (request.allow_session ?? true) result.push('session')
  if (request.allow_permanent ?? true) result.push('always')
  result.push('deny')
  return result
}

export interface ClarifyQuestion {
  qid: string
  question: string
  choices?: string[] | null
  multi_select?: boolean | null
}

export interface ClarifyRequest {
  session_id: string
  questions: ClarifyQuestion[]
  answers?: Record<string, string | null> | null
}

export interface SudoRequest {
  session_id: string
  command?: string | null
}

export interface SecretRequest {
  session_id: string
  env_var: string
  prompt: string
}

/** A server→client request (`tui_gateway/server_requests.py`). */
export interface ServerRequest {
  id: string
  method: string
  params: JSONValue
  /** Re-delivered from `open_requests` rather than received live. */
  replayed?: boolean
}

export type ServerRequestKind =
  | { kind: 'approval'; approval: ApprovalRequest }
  | { kind: 'clarify'; clarify: ClarifyRequest }
  | { kind: 'sudo'; sudo: SudoRequest }
  | { kind: 'secret'; secret: SecretRequest }
  | { kind: 'unsupported' }

export function requestSessionID(request: ServerRequest): string | undefined {
  const params = request.params
  if (!isObject(params)) return undefined
  return typeof params.session_id === 'string' ? params.session_id : undefined
}

/** Typed view of a request; unknown methods and malformed params are `unsupported`. */
export function requestKind(request: ServerRequest): ServerRequestKind {
  const p = request.params
  if (!isObject(p) || typeof p.session_id !== 'string') return { kind: 'unsupported' }
  switch (request.method) {
    case 'approval':
      if (typeof p.request_id !== 'string') return { kind: 'unsupported' }
      return { kind: 'approval', approval: p as unknown as ApprovalRequest }
    case 'clarify':
      if (!Array.isArray(p.questions)) return { kind: 'unsupported' }
      return { kind: 'clarify', clarify: p as unknown as ClarifyRequest }
    case 'sudo':
      return { kind: 'sudo', sudo: p as unknown as SudoRequest }
    case 'secret':
      if (typeof p.env_var !== 'string' || typeof p.prompt !== 'string') return { kind: 'unsupported' }
      return { kind: 'secret', secret: p as unknown as SecretRequest }
    default:
      return { kind: 'unsupported' }
  }
}

// MARK: - Events

export interface StreamDelta { text: string; rendered?: string; verbose?: boolean }
export interface MessageInterim { text: string; already_streamed?: boolean }
export interface MessageComplete {
  /** `str | JsonValue` in the contract; use `completeText`. */
  text?: JSONValue
  /** `complete` | `error` | `interrupted` */
  status?: string
  reasoning?: string
  error?: string
  warning?: string
  usage?: JSONValue
  persisted_turn?: { user_row_id?: number; row_ids?: number[] }
}
export interface ToolGenerating { name: string }
export interface ToolStart {
  tool_id: string
  name: string
  context?: string
  preview?: string
  args?: JSONValue
  args_text?: string
}
export interface ToolComplete {
  tool_id: string
  name: string
  args?: JSONValue
  duration_s?: number
  summary?: string
  result_text?: string
  result?: JSONValue
  inline_diff?: string
  todos?: JSONValue
  error?: string
}
export interface StatusUpdate { kind?: string; text: string }
export interface SessionTitleChange { session_id: string; title: string }
export interface RequestCancel { id: string; method?: string; reason?: string }
export interface ApprovalCancelled { reason?: string; request_ids: string[] }
export interface SideAgentComplete { task_id: string; text: string; question?: string }
export interface ReviewSummary { text: string }
export interface SessionReclaimed { session_id: string; stored_session_id?: string; reason?: string }
export interface GatewayNotice {
  text: string
  level?: string
  kind?: string
  ttl_ms?: number
  key?: string
  id?: string
}

/** Typed view of an event (HermesKit's `GatewayEventKind`); bad payloads are `unknown`. */
export type GatewayEventKind =
  | { kind: 'gatewayReady' }
  | { kind: 'messageStart' }
  | { kind: 'messageDelta'; delta: StreamDelta }
  | { kind: 'reasoningDelta'; delta: StreamDelta }
  | { kind: 'thinkingDelta'; delta: StreamDelta }
  | { kind: 'reasoningAvailable'; delta: StreamDelta }
  | { kind: 'messageInterim'; interim: MessageInterim }
  | { kind: 'messageComplete'; complete: MessageComplete }
  | { kind: 'toolGenerating'; generating: ToolGenerating }
  | { kind: 'toolStart'; start: ToolStart }
  | { kind: 'toolComplete'; complete: ToolComplete }
  | { kind: 'statusUpdate'; update: StatusUpdate }
  | { kind: 'sessionTitle'; change: SessionTitleChange }
  | { kind: 'sessionInfo'; info: SessionLiveInfo }
  | { kind: 'error'; message: string }
  | { kind: 'requestCancel'; cancel: RequestCancel }
  | { kind: 'approvalCancelled'; cancelled: ApprovalCancelled }
  | { kind: 'btwComplete'; answer: SideAgentComplete }
  | { kind: 'backgroundComplete'; answer: SideAgentComplete }
  | { kind: 'reviewSummary'; summary: ReviewSummary }
  | { kind: 'sessionsChanged' }
  | { kind: 'sessionReclaimed'; reclaimed: SessionReclaimed }
  | { kind: 'notificationShow'; notice: GatewayNotice }
  | { kind: 'notificationClear'; key: string }
  | { kind: 'unknown' }

function isObject(value: unknown): value is Record<string, JSONValue> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

const str = (value: unknown): value is string => typeof value === 'string'

/** Decodes `event.payload` by `event.type`, as HermesKit's `GatewayEvent.kind`. */
export function eventKind(event: GatewayEvent): GatewayEventKind {
  const p = (isObject(event.payload) ? event.payload : {}) as Record<string, any>
  const delta = (): StreamDelta | undefined => (str(p.text) ? (p as StreamDelta) : undefined)
  switch (event.type) {
    case 'gateway.ready': return str(p.replay_epoch) ? { kind: 'gatewayReady' } : { kind: 'unknown' }
    case 'message.start': return { kind: 'messageStart' }
    case 'message.delta': { const d = delta(); return d ? { kind: 'messageDelta', delta: d } : { kind: 'unknown' } }
    case 'reasoning.delta': { const d = delta(); return d ? { kind: 'reasoningDelta', delta: d } : { kind: 'unknown' } }
    case 'thinking.delta': { const d = delta(); return d ? { kind: 'thinkingDelta', delta: d } : { kind: 'unknown' } }
    case 'reasoning.available': { const d = delta(); return d ? { kind: 'reasoningAvailable', delta: d } : { kind: 'unknown' } }
    case 'message.interim':
      return str(p.text) ? { kind: 'messageInterim', interim: p as MessageInterim } : { kind: 'unknown' }
    case 'message.complete': {
      // Lenient: the terminal frame of every turn must never become `unknown`.
      const complete: MessageComplete = {}
      if (p.text !== undefined) complete.text = p.text
      if (str(p.status)) complete.status = p.status
      if (str(p.reasoning)) complete.reasoning = p.reasoning
      if (str(p.error)) complete.error = p.error
      if (str(p.warning)) complete.warning = p.warning
      if (p.usage !== undefined) complete.usage = p.usage
      if (isObject(p.persisted_turn)) {
        const turn = p.persisted_turn as Record<string, unknown>
        complete.persisted_turn = {}
        if (Number.isInteger(turn.user_row_id)) complete.persisted_turn.user_row_id = turn.user_row_id as number
        if (Array.isArray(turn.row_ids) && turn.row_ids.every(Number.isInteger)) {
          complete.persisted_turn.row_ids = turn.row_ids as number[]
        }
      }
      return { kind: 'messageComplete', complete }
    }
    case 'tool.generating': return str(p.name) ? { kind: 'toolGenerating', generating: p as ToolGenerating } : { kind: 'unknown' }
    case 'tool.start':
      return str(p.tool_id) && str(p.name) ? { kind: 'toolStart', start: p as ToolStart } : { kind: 'unknown' }
    case 'tool.complete': {
      if (!str(p.tool_id) || !str(p.name)) return { kind: 'unknown' }
      // `error` is outside the contract: another shape is dropped, not the whole event.
      const complete = { ...p } as ToolComplete
      if (!str(p.error)) delete complete.error
      return { kind: 'toolComplete', complete }
    }
    case 'status.update': return str(p.text) ? { kind: 'statusUpdate', update: p as StatusUpdate } : { kind: 'unknown' }
    case 'session.title':
      return str(p.session_id) && str(p.title) ? { kind: 'sessionTitle', change: p as SessionTitleChange } : { kind: 'unknown' }
    case 'session.info': return { kind: 'sessionInfo', info: p as SessionLiveInfo }
    case 'error': return str(p.message) ? { kind: 'error', message: p.message } : { kind: 'unknown' }
    case 'request.cancel': return str(p.id) ? { kind: 'requestCancel', cancel: p as RequestCancel } : { kind: 'unknown' }
    case 'approval.cancelled':
      return Array.isArray(p.request_ids) ? { kind: 'approvalCancelled', cancelled: p as ApprovalCancelled } : { kind: 'unknown' }
    case 'btw.complete':
      return str(p.task_id) && str(p.text) ? { kind: 'btwComplete', answer: p as SideAgentComplete } : { kind: 'unknown' }
    case 'background.complete':
      return str(p.task_id) && str(p.text) ? { kind: 'backgroundComplete', answer: p as SideAgentComplete } : { kind: 'unknown' }
    case 'review.summary': return str(p.text) ? { kind: 'reviewSummary', summary: p as ReviewSummary } : { kind: 'unknown' }
    case 'sessions.changed': return { kind: 'sessionsChanged' }
    case 'session.reclaimed':
      return str(p.session_id) ? { kind: 'sessionReclaimed', reclaimed: p as SessionReclaimed } : { kind: 'unknown' }
    case 'notification.show': return str(p.text) ? { kind: 'notificationShow', notice: p as GatewayNotice } : { kind: 'unknown' }
    case 'notification.clear': return str(p.key) ? { kind: 'notificationClear', key: p.key } : { kind: 'unknown' }
    default: return { kind: 'unknown' }
  }
}

/** `message.complete`'s text as display text: strings as-is, text parts joined, other JSON serialised. */
export function completeText(complete: MessageComplete): string {
  const text = complete.text
  if (text === undefined || text === null) return ''
  if (typeof text === 'string') return text
  if (Array.isArray(text) && text.every((part) => isObject(part) && typeof part.text === 'string')) {
    return text.map((part) => (part as { text: string }).text).join('')
  }
  return stableStringify(text)
}

/** JSON with sorted keys, as Swift's `JSONEncoder` with `.sortedKeys`. */
export function stableStringify(value: JSONValue): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`
  if (isObject(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key]!)}`).join(',')}}`
  }
  return JSON.stringify(value)
}
