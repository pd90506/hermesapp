import { DashboardConnector } from './connector.ts'
import { DashboardError } from './dashboard.ts'
import type { HttpRequest } from './http.ts'
import type { JSONValue } from './protocol/jsonrpc.ts'

/**
 * The dashboard's REST routes, with the connection's credential (HermesKit's
 * `DashboardAPI`): the settings that live in a profile's config (capabilities, providers),
 * cron jobs, search. Every profile route takes the profile it reads or writes as
 * `?profile=` (`apps/desktop/src/api/client.ts::capabilityScoped`).
 */
export interface DashboardAPI {
  /** One call: the decoded JSON answer, or a `DashboardRequestError` with the dashboard's reason. */
  send(method: HttpRequest['method'], path: string, options?: DashboardCallOptions): Promise<JSONValue>
}

export interface DashboardCallOptions {
  query?: ReadonlyArray<readonly [string, string]>
  body?: JSONValue
  timeoutMs?: number
}

/** A refused call whose answer named why (FastAPI's `{"detail": "..."}`; HermesKit's `CronRequestError`). */
export class DashboardRequestError extends Error {
  constructor(readonly status: number, readonly detail: string) {
    super(detail)
  }

  static from(error: unknown): unknown {
    if (!(error instanceof DashboardError) || error.kind !== 'http' || !error.reason) return error
    try {
      const detail = (JSON.parse(error.reason) as { detail?: unknown }).detail
      if (typeof detail === 'string' && detail !== '') return new DashboardRequestError(error.status ?? 0, detail)
    } catch {}
    return error
  }
}

/** The HTTP status of a refused call, when it has one. */
export function requestStatus(error: unknown): number | undefined {
  if (error instanceof DashboardRequestError) return error.status
  if (error instanceof DashboardError) return error.status
  return undefined
}

/** A name as one path segment (`DashboardPath.segment`). */
export function pathSegment(name: string): string {
  return encodeURIComponent(name).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase())
}

function scope(profile: string | undefined): Array<[string, string]> {
  return profile === undefined ? [] : [['profile', profile]]
}

export function profileGet(api: DashboardAPI, path: string, profile: string | undefined,
  query: ReadonlyArray<readonly [string, string]> = [], timeoutMs?: number): Promise<JSONValue> {
  return api.send('GET', path, { query: [...scope(profile), ...query], ...(timeoutMs ? { timeoutMs } : {}) })
}

export function profilePut(api: DashboardAPI, path: string, profile: string | undefined, body: JSONValue): Promise<JSONValue> {
  return api.send('PUT', path, { query: scope(profile), body })
}

export function profilePost(api: DashboardAPI, path: string, profile: string | undefined, body?: JSONValue): Promise<JSONValue> {
  return api.send('POST', path, { query: scope(profile), ...(body !== undefined ? { body } : {}) })
}

export function profileDelete(api: DashboardAPI, path: string, profile: string | undefined, body?: JSONValue): Promise<JSONValue> {
  return api.send('DELETE', path, { query: scope(profile), ...(body !== undefined ? { body } : {}) })
}

/**
 * `DashboardAPI` over a `DashboardConnector`, authenticated like its ticket mint so REST
 * and the socket share one sign-in (HermesKit's `DashboardConnector.authorized`):
 * - a token (`bearer`, `sessionToken`) goes in `Authorization: Bearer`;
 * - `password` uses the cookie session and logs in again once after a 401.
 */
export function dashboardAPI(connector: DashboardConnector): DashboardAPI {
  const { endpoint, credential, dashboard } = connector
  const once = (method: HttpRequest['method'], path: string, options: DashboardCallOptions) => {
    const request: HttpRequest = { method, url: endpoint.urlFor(path, options.query ?? []) }
    const headers: Record<string, string> = {}
    if (options.body !== undefined) {
      headers['Content-Type'] = 'application/json'
      request.body = JSON.stringify(options.body)
    }
    if (credential.kind === 'bearer') headers.Authorization = `Bearer ${credential.accessToken}`
    if (credential.kind === 'sessionToken') headers.Authorization = `Bearer ${credential.token}`
    request.headers = headers
    if (options.timeoutMs) request.timeoutMs = options.timeoutMs
    return dashboard.send<JSONValue>(request)
  }
  return {
    async send(method, path, options = {}) {
      try {
        try {
          return await once(method, path, options)
        } catch (error) {
          if (credential.kind !== 'password' || !(error instanceof DashboardError) || error.kind !== 'unauthenticated') throw error
          await dashboard.passwordLogin(credential.provider, credential.username, credential.password)
          return await once(method, path, options)
        }
      } catch (error) {
        throw DashboardRequestError.from(error)
      }
    },
  }
}

/** The REST routes of a connection's connector, when it has them. */
export function dashboardAPIFor(connector: unknown): DashboardAPI | undefined {
  return connector instanceof DashboardConnector ? dashboardAPI(connector) : undefined
}

/**
 * What a profile settings board reads and writes through: the connection's REST routes
 * and its socket (`GatewayConnection` is one).
 */
export interface GatewayAccess {
  readonly dashboardAPI: DashboardAPI | undefined
  call(method: string, params?: JSONValue): Promise<JSONValue>
}
