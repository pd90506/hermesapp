import { Bot, isListedSource, listedSources, type SessionSummary } from '../bots.ts'
import type { SessionsREST } from './rest.ts'

/**
 * A hit of the dashboard's session search (`GET /api/sessions/search`,
 * `hermes_cli/web_routers/sessions.py:286-463`; HermesKit's `SessionSearchHit`): a
 * stored conversation whose id, messages (FTS5) or title match, one per lineage,
 * resolved to the lineage's live tip.
 */
export interface SessionSearchHit {
  session_id: string
  lineage_root?: string | null
  title?: string | null
  /** Matched terms wrapped in `>>>` / `<<<` (`hermes_state_search.py:945`). */
  snippet?: string | null
  /** Whose message matched; null for id and title matches. */
  role?: string | null
  source?: string | null
  /** Unix seconds. */
  session_started?: number | null
  last_active?: number | null
  message_count?: number | null
  preview?: string | null
}

export interface SnippetSegment {
  text: string
  isMatch: boolean
}

/** The snippet on one line, split at the FTS markers, which never show (Desktop strips them). */
export function snippetSegments(snippet: string | null | undefined): SnippetSegment[] {
  let rest = (snippet ?? '').split(/\r?\n/).join(' ')
  const segments: SnippetSegment[] = []
  while (rest) {
    const open = rest.indexOf('>>>')
    if (open < 0) {
      segments.push({ text: rest, isMatch: false })
      break
    }
    if (open > 0) segments.push({ text: rest.slice(0, open), isMatch: false })
    const after = rest.slice(open + 3)
    const close = after.indexOf('<<<')
    segments.push({ text: close < 0 ? after : after.slice(0, close), isMatch: true })
    rest = close < 0 ? '' : after.slice(close + 3)
  }
  return segments.filter((segment) => segment.text)
}

/** When the conversation was last active, else when it started; epoch ms. */
export function hitDate(hit: SessionSearchHit): number | undefined {
  const seconds = hit.last_active ?? hit.session_started
  return seconds ? seconds * 1000 : undefined
}

/** How many hits a search asks for; the dashboard clamps to 1…100. */
export const searchLimit = 50

/** `GET /api/sessions/search?q=&profile=&sources=&limit=`, the listed sources only. */
export async function searchSessions(rest: SessionsREST, query: string, profile: string): Promise<SessionSearchHit[]> {
  const answer = await rest.send<{ results?: SessionSearchHit[] }>('GET', '/api/sessions/search', {
    query: { q: query, profile, limit: String(searchLimit), sources: listedSources.join(',') },
    // FTS over a large state.db is the dashboard's slowest read (`sessions.py:461-463`).
    timeoutMs: 30_000,
  })
  return answer.results ?? []
}

/** A hit as the list shows it: the row it opens, and whether that is the Bot Chat. */
export interface SessionSearchResult {
  hit: SessionSearchHit
  row: SessionSummary
  isBotChat: boolean
}

/** The hits the list may show, as rows: the listed row where there is one, so a hit pins and renames as that row. */
export function searchResults(hits: readonly SessionSearchHit[], listed: readonly SessionSummary[], bot: Bot | undefined): SessionSearchResult[] {
  const seen = new Set<string>()
  const results: SessionSearchResult[] = []
  for (const hit of hits) {
    if (!isListedSource(hit.source)) continue
    const row = listed.find((candidate) => candidate.id === hit.session_id || candidate.resolved_id === hit.session_id) ?? {
      id: hit.session_id,
      ...(hit.title != null ? { title: hit.title } : {}),
      ...(hit.preview != null ? { preview: hit.preview } : {}),
      ...(hit.session_started != null ? { started_at: hit.session_started } : {}),
      ...(hit.message_count != null ? { message_count: hit.message_count } : {}),
      ...(hit.source != null ? { source: hit.source } : {}),
    }
    if (seen.has(row.id)) continue
    seen.add(row.id)
    results.push({ hit, row, isBotChat: Bot.isBotChat(row, bot) })
  }
  return results
}
