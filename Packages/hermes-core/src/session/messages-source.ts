import { pathSegment, type DashboardAPI } from '../dashboard-api.ts'
import type { SessionMessagesPage, SessionMessagesQuery, SessionMessagesSource } from './types.ts'

/**
 * `GET /api/sessions/{id}/messages` (`hermes_cli/web_routers/sessions.py:685-729`), as
 * Desktop reads a transcript (`apps/desktop/src/api/sessions.ts:502-592`): newest page
 * first, compacted rows included, images left as `@image:` paths.
 */
export function messagesSource(api: DashboardAPI): SessionMessagesSource {
  return {
    async messagesPage(query: SessionMessagesQuery): Promise<SessionMessagesPage> {
      const params: Array<[string, string]> = []
      if (query.profile !== undefined) params.push(['profile', query.profile])
      params.push(['order', query.order ?? 'latest'], ['limit', String(query.limit)])
      if (query.offset !== undefined && query.offset > 0) params.push(['offset', String(query.offset)])
      params.push(['include_compacted', 'true'], ['inline_images', 'false'])
      const answer = await api.send('GET', `/api/sessions/${pathSegment(query.sessionID)}/messages`, { query: params })
      const page = (answer ?? {}) as unknown as Partial<SessionMessagesPage>
      return { ...page, messages: Array.isArray(page.messages) ? page.messages : [] }
    },
  }
}
