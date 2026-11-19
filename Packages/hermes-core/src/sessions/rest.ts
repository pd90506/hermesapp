import type { DashboardConnector } from '../connector.ts'
import { DashboardError } from '../dashboard.ts'
import { DashboardRequestError, requestStatus } from '../dashboard-api.ts'
import type { HttpRequest } from '../http.ts'
import { listedSources } from '../bots.ts'
import type { StoredMessage } from '../session/types.ts'

/**
 * The dashboard REST reads the sidebar needs: row activity, the shared read watermark,
 * search, over `connection.dashboardAPI` (the desktop adapts it, `sidebar-model.ts`).
 */
export interface SessionsREST {
  send<T>(method: HttpRequest['method'], path: string,
    options?: { query?: Record<string, string | undefined>; body?: unknown; timeoutMs?: number }): Promise<T>
}

/** Path segment, percent-encoded. */
function segment(value: string): string {
  return encodeURIComponent(value)
}

/**
 * A sender over `connector`'s credential, as HermesKit's `DashboardConnector.authorized`:
 * a token as `Authorization: Bearer`; a password through the cookie session, signing in
 * again once on a 401.
 */
export function restSender(connector: DashboardConnector): SessionsREST {
  const dashboard = connector.dashboard
  const credential = connector.credential
  return {
    async send<T>(method: HttpRequest['method'], path: string,
      options: { query?: Record<string, string | undefined>; body?: unknown; timeoutMs?: number } = {}): Promise<T> {
      const pairs = Object.entries(options.query ?? {}).filter((pair): pair is [string, string] => pair[1] !== undefined)
      const query = pairs.map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join('&')
      const build = (): HttpRequest => {
        const headers: Record<string, string> = {}
        if (credential.kind === 'bearer') headers.Authorization = `Bearer ${credential.accessToken}`
        if (credential.kind === 'sessionToken') headers.Authorization = `Bearer ${credential.token}`
        const request: HttpRequest = { method, url: dashboard.endpoint.urlFor(path) + (query ? `?${query}` : ''), headers }
        if (options.body !== undefined) {
          headers['Content-Type'] = 'application/json'
          request.body = JSON.stringify(options.body)
        }
        if (options.timeoutMs !== undefined) request.timeoutMs = options.timeoutMs
        return request
      }
      try {
        return await dashboard.send<T>(build())
      } catch (error) {
        if (credential.kind !== 'password' || !(error instanceof DashboardError && error.kind === 'unauthenticated')) throw error
        await dashboard.passwordLogin(credential.provider, credential.username, credential.password)
        return dashboard.send<T>(build())
      }
    },
  }
}

export interface MessagesPage {
  messages: StoredMessage[]
  pagination?: { order?: string | null } | null
}

export interface TimelinePage {
  entries: { timestamp?: number | null }[]
  pagination?: { has_more?: boolean | null; next_cursor?: number | null } | null
}

/**
 * `GET /api/sessions/{id}/messages?order=latest&limit=1` (`web_routers/sessions.py:685-729`):
 * the newest stored message, or undefined when the server can't page from the end.
 */
export async function newestMessage(rest: SessionsREST, sessionID: string, profile: string): Promise<StoredMessage | undefined> {
  const page = await rest.send<MessagesPage>('GET', `/api/sessions/${segment(sessionID)}/messages`, {
    query: { profile, order: 'latest', limit: '1', offset: '0', include_compacted: 'true', inline_images: 'false' },
  })
  // Older servers can ignore paging or order: never label an oldest page as newest.
  if (page.pagination?.order !== 'latest' || (page.messages?.length ?? 0) > 1) return undefined
  return page.messages.at(-1)
}

/** `GET /api/sessions/{id}/timeline` (`web_routers/sessions.py:801-820`): one page of the user's prompts. */
export function timelinePage(rest: SessionsREST, sessionID: string, profile: string, afterRowID: number): Promise<TimelinePage> {
  return rest.send<TimelinePage>('GET', `/api/sessions/${segment(sessionID)}/timeline`, {
    query: { profile, limit: '500', after_row_id: String(afterRowID) },
  })
}

/** Most rows `GET /api/sessions` answers (`le=100`, `sessions.py:181-184`). */
export const readWatermarkLimit = 100

/**
 * `GET /api/sessions?order=recent`: when each recently active session was last read
 * (`sessions.last_read_at`, `hermes_state_sessions.py:1062-1074`), Unix seconds by id;
 * 0 for one never marked. Only this REST list carries it; `session.list` rows don't.
 */
export async function readWatermarks(rest: SessionsREST, profile: string): Promise<Map<string, number>> {
  const answer = await rest.send<{ sessions?: { id: string; last_read_at?: number | null }[] }>('GET', '/api/sessions', {
    query: { profile, limit: String(readWatermarkLimit), order: 'recent', sources: listedSources.join(',') },
  })
  const marks = new Map<string, number>()
  for (const row of answer.sessions ?? []) marks.set(row.id, Math.max(marks.get(row.id) ?? 0, row.last_read_at ?? 0))
  return marks
}

/**
 * Marks a session read up to the server's now: `PATCH /api/sessions/{id} {unread: false}`,
 * fenced by `GET /api/sessions/{id}/mutation-snapshot`'s revision and generation, as
 * Desktop writes it (`apps/desktop/src/api/sessions.ts:380-428`). One more try when a
 * turn moved the revision in between.
 */
export async function markRead(rest: SessionsREST, sessionID: string, profile: string,
  requestID: () => string = randomID): Promise<void> {
  const once = async () => {
    const snapshot = await rest.send<{ exists: boolean; runtime_revision: number; runtime_generation?: number | null }>(
      'GET', `/api/sessions/${segment(sessionID)}/mutation-snapshot`, { query: { profile } })
    if (!snapshot.exists) return
    const body: Record<string, unknown> = {
      unread: false, request_id: requestID(), expected_revision: snapshot.runtime_revision, profile,
    }
    if (snapshot.runtime_generation != null) body.expected_generation = snapshot.runtime_generation
    await rest.send('PATCH', `/api/sessions/${segment(sessionID)}`, { body })
  }
  try {
    await once()
  } catch (error) {
    // The refusal as the connector's sender throws it, or as `dashboardAPI` re-throws it.
    const reason = error instanceof DashboardRequestError ? error.detail : error instanceof DashboardError ? error.reason : undefined
    const conflict = requestStatus(error) === 409 && /revision_conflict|stale_generation/.test(reason ?? '')
    if (!conflict) throw error
    await once()
  }
}

function randomID(): string {
  const hex = '0123456789abcdef'
  let id = ''
  for (let index = 0; index < 32; index++) id += hex[Math.floor(Math.random() * 16)]
  return `${id.slice(0, 8)}-${id.slice(8, 12)}-4${id.slice(13, 16)}-a${id.slice(17, 20)}-${id.slice(20)}`
}
