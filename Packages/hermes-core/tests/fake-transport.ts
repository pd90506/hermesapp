import type { MessageTransport } from '../src/index.ts'

/** A scripted socket (HermesKit's `FakeTransport`): records what the client sends. */
export class FakeTransport implements MessageTransport {
  readonly sent: Array<Record<string, unknown>> = []
  closed = false
  connectError?: Error
  /** Answers a request frame; return undefined to leave it unanswered. */
  respond?: (frame: Record<string, unknown>) => unknown
  private message?: (text: string) => void
  private close_?: (error?: Error) => void

  async connect(): Promise<void> {
    if (this.connectError) throw this.connectError
  }

  async send(text: string): Promise<void> {
    const frame = JSON.parse(text) as Record<string, unknown>
    this.sent.push(frame)
    const answer = this.respond?.(frame)
    if (answer !== undefined) queueMicrotask(() => this.push(answer))
  }

  onMessage(handler: (text: string) => void): void {
    this.message = handler
  }

  onClose(handler: (error?: Error) => void): void {
    this.close_ = handler
  }

  async close(): Promise<void> {
    this.closed = true
  }

  /** A frame from the server. */
  push(frame: unknown): void {
    this.message?.(JSON.stringify(frame))
  }

  /** The server drops the socket. */
  drop(error = new Error('network down')): void {
    this.close_?.(error)
  }

  ready(epoch = 'e1', heartbeat = false): void {
    this.push({ jsonrpc: '2.0', method: 'event', params: { type: 'gateway.ready', payload: { replay_epoch: epoch, heartbeat } } })
  }

  methods(): string[] {
    return this.sent.map((frame) => String(frame.method ?? ''))
  }
}

/** Answers `client.capabilities` and the given methods with results. */
export function answering(results: Record<string, unknown | ((params: any) => unknown)>) {
  return (frame: Record<string, unknown>) => {
    if (frame.id === undefined || typeof frame.method !== 'string') return undefined
    if (frame.method === 'client.capabilities') {
      return { jsonrpc: '2.0', id: frame.id, result: { server_requests: ['approval'] } }
    }
    const entry = results[frame.method]
    if (entry === undefined) return undefined
    const result = typeof entry === 'function' ? (entry as (params: unknown) => unknown)(frame.params) : entry
    return { jsonrpc: '2.0', id: frame.id, result }
  }
}
