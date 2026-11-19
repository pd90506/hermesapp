import type { MessageTransport } from './http.ts'
import type { GatewayMethodName, GatewayParams, GatewayResult } from './protocol/contract.generated.ts'
import {
  RPCError, decodeMessage, encodeRequest, encodeResponse,
  type JSONValue, type RPCErrorBody,
} from './protocol/jsonrpc.ts'
import {
  EventType, GatewayMethod, ServerRequestMethod, declineServerRequest, eventNotificationMethod,
} from './protocol/methods.ts'

/** The `params` of an `event` notification (`_event_frame`, `tui_gateway/server.py:693-696`). */
export interface GatewayEvent {
  type: string
  /** Runtime session id; empty or absent for connection-global events. */
  session_id?: string
  payload?: JSONValue
  /** Per-session counter, only on events with a session id. */
  seq?: number
}

/** `gateway.ready`'s payload. */
export interface GatewayReady {
  /** Random per backend process: a change across reconnects voids seq watermarks. */
  replay_epoch: string
  change_events?: boolean
  /** When true the client sends `gateway.ping` periodically. */
  heartbeat?: boolean
  skin?: JSONValue
}

export interface ServerRequest {
  id: string
  method: string
  params: JSONValue
}

export type ClientErrorKind =
  | 'notConnected' | 'alreadyConnected' | 'connectionClosed' | 'readyTimeout'
  | 'heartbeatTimeout' | 'timeout'

export class GatewayClientError extends Error {
  constructor(readonly kind: ClientErrorKind, detail?: string) {
    super(detail ?? kind)
  }
}

export interface GatewayClientConfiguration {
  requestTimeoutMs: number
  readyTimeoutMs: number
  /** `undefined` disables heartbeats; used only when `gateway.ready.heartbeat` is true. */
  heartbeatIntervalMs?: number
  heartbeatTimeoutMs: number
  /** Server requests delivered to subscribers; every other one is declined at once. */
  supportedServerRequests: ReadonlySet<string>
}

export const defaultClientConfiguration: GatewayClientConfiguration = {
  requestTimeoutMs: 120_000,
  readyTimeoutMs: 15_000,
  heartbeatIntervalMs: 15_000,
  heartbeatTimeoutMs: 45_000,
  supportedServerRequests: ServerRequestMethod.mvpSupported,
}

export type Inbound =
  | { kind: 'event'; event: GatewayEvent }
  | { kind: 'serverRequest'; request: ServerRequest }
  /** Terminal. `error` is undefined for a deliberate `close()`. */
  | { kind: 'disconnected'; error?: Error }

type State = 'idle' | 'connecting' | 'connected' | 'closed'

interface Pending {
  resolve(value: JSONValue): void
  reject(error: Error): void
  timer: ReturnType<typeof setTimeout>
}

/**
 * JSON-RPC client for one gateway WebSocket (HermesKit's `GatewayClient`):
 * - waits for `gateway.ready`, then sends `client.capabilities {server_requests: true}`;
 * - correlates request ids (`r1`, `r2`, ...) with responses, with timeouts;
 * - fans out events and server requests, dropping events whose `seq` was already seen;
 * - declines unsupported server requests (4404 for window-owned bridges, else -32601);
 * - sends `gateway.ping` and drops a connection that stays silent.
 *
 * One instance per connection: tickets are single-use, so reconnecting means a new
 * client on a new transport (`GatewayConnection` does that).
 */
export class GatewayClient {
  private state: State = 'idle'
  ready?: GatewayReady
  /** Highest `seq` seen per runtime session id. */
  readonly lastSeq = new Map<string, number>()
  private readonly configuration: GatewayClientConfiguration
  private readonly pending = new Map<string, Pending>()
  private readonly subscribers = new Set<(item: Inbound) => void>()
  private readonly openServerRequests = new Set<string>()
  private readyWaiter?: { resolve(ready: GatewayReady): void; reject(error: Error): void }
  private nextRequest = 0
  private heartbeatNumber = 0
  private lastInbound = Date.now()
  private heartbeat?: ReturnType<typeof setInterval>

  constructor(private readonly transport: MessageTransport, configuration: Partial<GatewayClientConfiguration> = {}) {
    this.configuration = { ...defaultClientConfiguration, ...configuration }
  }

  get isConnected(): boolean {
    return this.state === 'connected'
  }

  /** Inbound events, server requests and the final disconnect. Returns an unsubscribe. */
  subscribe(handler: (item: Inbound) => void): () => void {
    if (this.state === 'closed') {
      handler({ kind: 'disconnected', error: new GatewayClientError('connectionClosed') })
      return () => {}
    }
    this.subscribers.add(handler)
    return () => this.subscribers.delete(handler)
  }

  /** Opens the transport, waits for `gateway.ready` and advertises server-request support. */
  async connect(): Promise<GatewayReady> {
    if (this.state !== 'idle') throw new GatewayClientError('alreadyConnected')
    this.state = 'connecting'
    this.transport.onMessage((text) => this.receive(text))
    this.transport.onClose((error) => {
      void this.ended(error ?? new GatewayClientError('connectionClosed', 'closed by server'))
    })
    try {
      await this.transport.connect()
    } catch (error) {
      this.state = 'closed'
      this.finishSubscribers(asError(error))
      throw error
    }
    this.lastInbound = Date.now()
    try {
      const ready = await this.waitForReady()
      this.state = 'connected'
      await this.call(GatewayMethod.clientCapabilities, { server_requests: true })
      const interval = this.configuration.heartbeatIntervalMs
      if (ready.heartbeat === true && interval !== undefined) this.startHeartbeat(interval)
      return ready
    } catch (error) {
      await this.ended(asError(error))
      throw error
    }
  }

  /** Closes the connection deliberately; pending calls fail with `connectionClosed`. */
  close(): Promise<void> {
    return this.ended(undefined)
  }

  /** A typed call of a contract method. */
  request<M extends GatewayMethodName>(method: M, params: GatewayParams<M>, timeoutMs?: number): Promise<GatewayResult<M>> {
    return this.call(method, params as unknown as JSONValue, timeoutMs) as Promise<GatewayResult<M>>
  }

  /** Sends a request and resolves with its result, or rejects with an `RPCError`. */
  call(method: string, params?: JSONValue, timeoutMs?: number): Promise<JSONValue> {
    if (this.state !== 'connecting' && this.state !== 'connected') {
      return Promise.reject(new GatewayClientError('notConnected'))
    }
    this.nextRequest += 1
    const id = `r${this.nextRequest}`
    const frame = encodeRequest(id, method, params)
    return new Promise<JSONValue>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new GatewayClientError('timeout', method))
      }, timeoutMs ?? this.configuration.requestTimeoutMs)
      this.pending.set(id, { resolve, reject, timer })
      this.write(frame)
    })
  }

  /** Answers a server request. */
  respond(requestID: string, outcome: { result: JSONValue } | { error: RPCErrorBody }): void {
    if (this.state !== 'connecting' && this.state !== 'connected') throw new GatewayClientError('notConnected')
    this.openServerRequests.delete(requestID)
    this.write(encodeResponse(requestID, outcome))
  }

  private write(frame: string): void {
    this.transport.send(frame).catch((error) => void this.ended(asError(error)))
  }

  private waitForReady(): Promise<GatewayReady> {
    if (this.ready) return Promise.resolve(this.ready)
    return new Promise<GatewayReady>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.readyWaiter = undefined
        reject(new GatewayClientError('readyTimeout'))
      }, this.configuration.readyTimeoutMs)
      this.readyWaiter = {
        resolve: (ready) => { clearTimeout(timer); resolve(ready) },
        reject: (error) => { clearTimeout(timer); reject(error) },
      }
    })
  }

  private async ended(error: Error | undefined): Promise<void> {
    if (this.state === 'closed') return
    this.state = 'closed'
    if (this.heartbeat) clearInterval(this.heartbeat)
    const closed = new GatewayClientError('connectionClosed', error?.message)
    for (const call of this.pending.values()) {
      clearTimeout(call.timer)
      call.reject(closed)
    }
    this.pending.clear()
    this.readyWaiter?.reject(error ?? closed)
    this.readyWaiter = undefined
    this.openServerRequests.clear()
    this.finishSubscribers(error)
    await this.transport.close().catch(() => {})
  }

  private finishSubscribers(error: Error | undefined): void {
    const item: Inbound = error ? { kind: 'disconnected', error } : { kind: 'disconnected' }
    for (const handler of [...this.subscribers]) handler(item)
    this.subscribers.clear()
  }

  private startHeartbeat(intervalMs: number): void {
    this.heartbeat = setInterval(() => {
      if (this.state !== 'connected') return
      if (Date.now() - this.lastInbound > this.configuration.heartbeatTimeoutMs) {
        void this.ended(new GatewayClientError('heartbeatTimeout'))
        return
      }
      this.heartbeatNumber += 1
      // Not tracked as pending: any inbound frame counts as liveness.
      this.write(encodeRequest(`heartbeat-${this.heartbeatNumber}`, GatewayMethod.gatewayPing))
    }, intervalMs)
  }

  private receive(text: string): void {
    this.lastInbound = Date.now()
    const message = decodeMessage(text)
    if (!message) return
    if (message.kind === 'response') {
      const { id, result, error } = message.response
      const call = id === null ? undefined : this.pending.get(String(id))
      if (!call) return // a heartbeat reply, or a late answer to a timed-out call
      this.pending.delete(String(id))
      clearTimeout(call.timer)
      if (error) call.reject(new RPCError(error))
      else call.resolve(result ?? null)
      return
    }
    const { id, method, params } = message.request
    if (id === undefined) {
      if (method === eventNotificationMethod && isEvent(params)) this.receiveEvent(params)
      return
    }
    if (this.configuration.supportedServerRequests.has(method)) {
      if (this.openServerRequests.has(String(id))) return
      this.openServerRequests.add(String(id))
      this.broadcast({ kind: 'serverRequest', request: { id: String(id), method, params: params ?? {} } })
    } else {
      this.write(encodeResponse(id, { error: declineServerRequest(method) }))
    }
  }

  private receiveEvent(event: GatewayEvent): void {
    if (event.type === EventType.gatewayReady && isObject(event.payload) &&
        typeof event.payload.replay_epoch === 'string') {
      this.ready = event.payload as unknown as GatewayReady
      this.readyWaiter?.resolve(this.ready)
      this.readyWaiter = undefined
    }
    const sid = event.session_id
    if (sid && typeof event.seq === 'number') {
      const last = this.lastSeq.get(sid)
      if (last !== undefined && event.seq <= last) return
      this.lastSeq.set(sid, event.seq)
    }
    if (event.type === EventType.requestCancel && isObject(event.payload) && typeof event.payload.id === 'string') {
      this.openServerRequests.delete(event.payload.id)
    }
    this.broadcast({ kind: 'event', event })
  }

  private broadcast(item: Inbound): void {
    for (const handler of [...this.subscribers]) handler(item)
  }
}

function isObject(value: unknown): value is Record<string, JSONValue> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isEvent(value: unknown): value is GatewayEvent {
  return isObject(value) && typeof value.type === 'string'
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error))
}
