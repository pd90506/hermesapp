/**
 * HTTP and WebSocket access, injected by the app (HermesKit's `HTTPClient` and
 * `MessageTransport`). The core makes no request itself: the desktop app sends them from
 * Electron's main process, which keeps the dashboard's session cookie and sends no
 * browser `Origin` (docs/desktop-electron.md, "Where requests run"). Tests use fakes.
 */
export interface HttpRequest {
  method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
  url: string
  headers?: Record<string, string>
  /** A JSON body, already encoded. */
  body?: string
  /** Milliseconds; HermesKit's 15 s by default. */
  timeoutMs?: number
}

export interface HttpResponse {
  status: number
  body: string
}

export interface HttpClient {
  send(request: HttpRequest): Promise<HttpResponse>
  /** Forgets the cookies this client keeps (a new sign-in, another server). */
  reset?(): Promise<void>
}

/** One WebSocket connection: text frames in and out. */
export interface MessageTransport {
  /** Opens the socket; rejects with `TransportError` when the upgrade is refused. */
  connect(): Promise<void>
  send(text: string): Promise<void>
  /** Each inbound text frame, then `onClose` once. */
  onMessage(handler: (text: string) => void): void
  /** `error` is undefined for a close this side asked for. */
  onClose(handler: (error?: Error) => void): void
  close(): Promise<void>
}

export class TransportError extends Error {
  constructor(readonly kind: 'handshakeFailed' | 'closed' | 'network', detail: string) {
    super(detail)
  }
}
