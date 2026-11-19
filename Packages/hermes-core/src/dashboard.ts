import type { GatewayEndpoint } from './endpoint.ts'
import type { HttpClient, HttpRequest } from './http.ts'

/** Public subset of `GET /api/status` (`hermes_cli/web_routers/status.py`). */
export interface DashboardStatus {
  version?: string
  release_date?: string
  /** True when the dashboard is gated by a session provider. */
  auth_required?: boolean
  auth_providers?: string[]
  /** `cookie` and/or `native_pkce`. */
  auth_flows?: string[]
  gateway_running?: boolean
  gateway_state?: string
}

/** A single-use WebSocket ticket from `POST /api/auth/ws-ticket` (30 s TTL). */
export interface WebSocketTicket {
  ticket: string
  ttl_seconds?: number
}

export type DashboardErrorKind =
  /** 401: missing or expired credentials. */
  | 'unauthenticated'
  /** 401 from `/auth/password-login`: wrong username or password. */
  | 'invalidCredentials'
  /** 429 from the login rate limiter. */
  | 'rateLimited'
  | 'http'
  | 'invalidResponse'

export class DashboardError extends Error {
  constructor(readonly kind: DashboardErrorKind, readonly status?: number, readonly reason?: string) {
    super(reason ?? kind)
  }
}

/** HTTP calls against the Hermes dashboard (HermesKit's `DashboardClient`). */
export class DashboardClient {
  constructor(readonly endpoint: GatewayEndpoint, private readonly http: HttpClient) {}

  /** `GET /api/status`: public, tells whether sign-in is needed. */
  status(): Promise<DashboardStatus> {
    return this.send({ method: 'GET', url: this.endpoint.urlFor('/api/status') })
  }

  /**
   * `POST /auth/password-login` for password providers such as `basic`. The session
   * arrives as `Set-Cookie` only; the HTTP client keeps it for later calls.
   */
  async passwordLogin(provider: string, username: string, password: string): Promise<void> {
    try {
      await this.send(this.json('POST', '/auth/password-login', { provider, username, password, next: '' }))
    } catch (error) {
      if (error instanceof DashboardError && error.kind === 'unauthenticated') {
        throw new DashboardError('invalidCredentials', 401)
      }
      throw error
    }
  }

  /** `POST /api/auth/ws-ticket`, by `bearer` when given, else by the session cookie. */
  mintWebSocketTicket(bearer?: string): Promise<WebSocketTicket> {
    const request: HttpRequest = { method: 'POST', url: this.endpoint.urlFor('/api/auth/ws-ticket') }
    if (bearer) request.headers = { Authorization: `Bearer ${bearer}` }
    return this.send(request)
  }

  private json(method: HttpRequest['method'], path: string, body: unknown): HttpRequest {
    return {
      method,
      url: this.endpoint.urlFor(path),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }
  }

  async send<T>(request: HttpRequest): Promise<T> {
    const response = await this.http.send({
      timeoutMs: 15_000,
      ...request,
      headers: { Accept: 'application/json', ...request.headers },
    })
    if (response.status >= 200 && response.status < 300) {
      try {
        return JSON.parse(response.body) as T
      } catch (error) {
        throw new DashboardError('invalidResponse', response.status, String(error))
      }
    }
    if (response.status === 401) {
      let reason: string | undefined
      try {
        const body = JSON.parse(response.body) as { reason?: unknown; error?: unknown }
        const value = body.reason ?? body.error
        if (typeof value === 'string') reason = value
      } catch {}
      throw new DashboardError('unauthenticated', 401, reason)
    }
    if (response.status === 429) throw new DashboardError('rateLimited', 429)
    throw new DashboardError('http', response.status, response.body || undefined)
  }
}
