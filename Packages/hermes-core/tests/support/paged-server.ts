import {
  GatewayConnection, type GatewayConnector, type MessageTransport, type SessionMessagesPage, type SessionMessagesQuery,
  type SessionMessagesSource, type StoredMessage,
} from '../../src/index.ts'
import { FakeTransport } from '../fake-transport.ts'

// A scripted gateway and stored transcript (HermesKit's `PagedServer` and
// `FakeMessageStore`, Tests/HermesKitTests/Support). Payloads follow what Hermes sends;
// the Swift helpers cite the server code for each.

export function storedRow(id: number, role = id % 2 === 1 ? 'user' : 'assistant', text = `row ${id}`): StoredMessage {
  return { id, role, content: text, timestamp: 1_700_000_000 + id }
}

export function rows(from: number, to: number): StoredMessage[] {
  return Array.from({ length: to - from + 1 }, (_, index) => storedRow(from + index))
}

/** `GET /api/sessions/{id}/messages` over a list of rows, `order=latest` paging. */
export class FakeMessageStore implements SessionMessagesSource {
  queries: SessionMessagesQuery[] = []
  /** Fails the next reads with this error. */
  failures: Error[] = []
  constructor(public rows: StoredMessage[] = []) {}

  append(more: StoredMessage[]): void {
    this.rows = [...this.rows, ...more]
  }

  nextID(): number {
    return (this.rows.at(-1)?.id ?? 0) + 1
  }

  async messagesPage(query: SessionMessagesQuery): Promise<SessionMessagesPage> {
    this.queries.push(query)
    const failure = this.failures.shift()
    if (failure) throw failure
    const offset = query.offset ?? 0
    if ((query.order ?? 'latest') === 'latest') {
      const end = Math.max(0, this.rows.length - offset)
      const start = Math.max(0, end - query.limit)
      return { messages: this.rows.slice(start, end), pagination: { limit: query.limit, offset, order: 'latest' } }
    }
    return { messages: this.rows.slice(offset, offset + query.limit), pagination: { limit: query.limit, offset, order: 'oldest' } }
  }
}

/** `message.complete` with its receipt (`prompt_turn.py:873-922`). */
export function completePayload(text: string, rowIDs: number[]) {
  return {
    text, status: 'complete',
    persisted_turn: { row_ids: rowIDs, complete: true, user_row_id: rowIDs[0], final_assistant_row_id: rowIDs.at(-1) },
  }
}

export interface Frame { id?: string; method?: string; params?: Record<string, unknown> }

/** A gateway whose sessions all read from one stored transcript. */
export class PagedServer {
  readonly sockets: FakeTransport[] = []
  epoch = 'E1'
  counter = 0
  readonly keysBySID = new Map<string, string>()
  /** When set, `session.resume` finds the session live with this turn running. */
  runningTurn?: Record<string, unknown>
  /** Methods left unanswered; answer with `answer(frame, result)`. */
  readonly held = new Set<string>()
  readonly heldFrames: Frame[] = []
  /** Bot Chat registry lookup: the tip it names, or none. */
  botTip: string | undefined = 'coder-chat'
  /** The replay `session.events.since` answers. */
  replay: { events: unknown[]; latest_seq: number; truncated?: boolean; epoch?: string } | undefined
  /** Fails these methods with this RPC error. */
  readonly errors = new Map<string, { code: number; message: string }>()

  constructor(readonly store = new FakeMessageStore()) {}

  get socket(): FakeTransport {
    return this.sockets.at(-1)!
  }

  /** The params of every call of `method` on any socket. */
  calls(method: string): Array<Record<string, unknown>> {
    return this.sockets.flatMap((socket) => socket.sent)
      .filter((frame) => frame.method === method).map((frame) => (frame.params ?? {}) as Record<string, unknown>)
  }

  connector(): GatewayConnector {
    return {
      messagesSource: this.store,
      makeTransport: async (): Promise<MessageTransport> => {
        const socket = new FakeTransport()
        socket.respond = (frame) => this.respond(frame as Frame)
        const connect = socket.connect.bind(socket)
        socket.connect = async () => {
          await connect()
          queueMicrotask(() => socket.ready(this.epoch))
        }
        this.sockets.push(socket)
        return socket
      },
    }
  }

  /** A connected connection, roster loaded. */
  async connect(): Promise<GatewayConnection> {
    const connection = new GatewayConnection({ client: { heartbeatIntervalMs: undefined }, backoff: () => 1 })
    await connection.connect(this.connector())
    await connection.settled()
    return connection
  }

  answer(frame: Frame, result: unknown): void {
    this.socket.push({ jsonrpc: '2.0', id: frame.id, result })
  }

  event(type: string, sid: string, seq: number | undefined, payload: unknown = {}): void {
    this.socket.push({ jsonrpc: '2.0', method: 'event', params: { type, session_id: sid, ...(seq !== undefined ? { seq } : {}), payload } })
  }

  request(id: string, method: string, params: Record<string, unknown>): void {
    this.socket.push({ jsonrpc: '2.0', id, method, params })
  }

  private respond(frame: Frame): unknown {
    if (frame.id === undefined || typeof frame.method !== 'string') return undefined
    const error = this.errors.get(frame.method)
    if (error) return { jsonrpc: '2.0', id: frame.id, error }
    if (this.held.has(frame.method)) {
      this.heldFrames.push(frame)
      return undefined
    }
    const result = this.result(frame.method, frame.params ?? {})
    if (result === undefined) return undefined
    return { jsonrpc: '2.0', id: frame.id, result }
  }

  private result(method: string, params: Record<string, unknown>): unknown {
    const count = this.store.rows.length
    switch (method) {
      case 'client.capabilities':
        return { server_requests: ['approval', 'sudo', 'secret'] }
      case 'profiles.list':
        return {
          profiles: [
            { name: 'default', is_default: true },
            { name: 'coder', canonical_session: this.botTip ? { id: 'coder-chat', resolved_id: this.botTip } : null },
          ],
        }
      case 'session.list':
        if (params.title === 'Bot Chat') {
          return {
            sessions: this.botTip
              ? [{ id: 'coder-chat', resolved_id: this.botTip, title: 'Bot Chat', message_count: count, source: 'desktop' }]
              : [],
          }
        }
        return { sessions: [{ id: 'stored-1', title: 'Earlier', message_count: count, source: 'desktop' }] }
      case 'session.resume': {
        // `_resume_deferred` (`methods_session.py:898-914,949-967`), or a live session's
        // payload when a turn runs (`server.py:3146-3186`).
        const key = String(params.session_id)
        this.counter += 1
        const sid = `rt-${this.counter}`
        this.keysBySID.set(sid, key)
        if (this.runningTurn) {
          return { session_id: sid, resumed: key, session_key: key, message_count: count, messages: [], messages_omitted: true,
            hydrating: false, info: { model: 'test-model' }, running: true, status: 'working', inflight: this.runningTurn }
        }
        return { session_id: sid, resumed: key, session_key: key, message_count: count, messages: [], hydrating: true,
          info: { model: 'test-model' }, inflight: null, running: false, status: 'resuming' }
      }
      case 'session.create': {
        this.counter += 1
        const sid = `rt-${this.counter}`
        const key = `new-${this.counter}`
        this.keysBySID.set(sid, key)
        return { session_id: sid, stored_session_id: key, message_count: 0, messages: [], info: { model: 'test-model' } }
      }
      case 'session.title':
        return { title: params.title, pending: false }
      case 'session.activate': {
        const sid = String(params.session_id)
        return { session_id: sid, session_key: this.keysBySID.get(sid) ?? sid, message_count: count, messages: [],
          messages_omitted: true, info: { model: 'test-model' }, running: false, status: 'idle', inflight: null }
      }
      case 'session.events.since':
        return { events: [], latest_seq: 0, count: 0, open_requests: [], ...this.replay, epoch: this.replay?.epoch ?? this.epoch }
      case 'prompt.submit': {
        // The prompt's row is written at submit (`methods_prompt.py:817-820`).
        const id = this.store.nextID()
        this.store.append([storedRow(id, 'user', String(params.text))])
        return { status: 'streaming', user_row_id: id }
      }
      case 'session.interrupt':
        return { status: 'interrupted' }
      default:
        return undefined
    }
  }
}

/** Resolves once `check` holds, polling microtasks and timers. */
export async function eventually(check: () => boolean, timeoutMs = 2000): Promise<boolean> {
  const start = Date.now()
  while (!check()) {
    if (Date.now() - start > timeoutMs) return false
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 1))
  }
  return true
}
