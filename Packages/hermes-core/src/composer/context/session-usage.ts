import type { GatewayEvent } from '../../client.ts'
import { Observable } from '../../observable.ts'
import type { JSONValue } from '../../protocol/jsonrpc.ts'
import type { ChatSession } from '../../session/chat-session.ts'

/**
 * A live session's token use, as `_get_usage` reports it (`tui_gateway/server.py:1389-1438`):
 * on `session.info`, `message.complete`, `session.usage` (event and call). HermesKit's
 * `SessionUsage`; Desktop's status bar shows the same.
 */
export interface SessionUsage {
  input: number
  output: number
  total: number
  /** Model calls this session made. */
  calls: number
  reasoning?: number
  /** Tokens the last prompt filled, of `contextMax`. */
  contextUsed?: number
  contextMax?: number
  contextPercent?: number
  /** The occupancy is an estimate, not the provider's count. */
  contextEstimated: boolean
  compressions?: number
  /** The prompt cache's hit rate, 0…100; absent before any cache read. */
  cacheHitPercent?: number
  /** Output tokens per second over the last calls. */
  tokensPerSecond?: number
  costUSD?: number
  model?: string
}

/** One thing that fills the context (`session.context_breakdown` categories). */
export interface ContextCategory {
  id: string
  label: string
  tokens: number
}

/**
 * What fills a session's context (`session.context_breakdown`,
 * `tui_gateway/methods_session.py:1459-1490`): the system prompt, tools, memory, skills
 * and messages, estimated from the live runtime. It answers for a chat no turn measured yet.
 */
export interface ContextBreakdown {
  categories: ContextCategory[]
  contextUsed: number
  contextMax: number
  contextPercent: number
  contextEstimated: boolean
  model?: string
}

/** How full the chat's context is, as the composer's gauge shows it. */
export interface ContextGauge {
  used: number
  max: number
  /** 0…100. */
  percent: number
  isEstimated: boolean
}

const record = (value: unknown): Record<string, JSONValue> | undefined =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, JSONValue> : undefined
const number = (value: unknown): number | undefined => typeof value === 'number' && Number.isFinite(value) ? value : undefined

/** The usage object; `undefined` for anything else, or one with no counter at all. */
export function parseSessionUsage(value: JSONValue | undefined | null): SessionUsage | undefined {
  const row = record(value)
  if (!row) return undefined
  const int = (key: string): number | undefined => {
    const read = number(row[key])
    return read === undefined ? undefined : Math.round(read)
  }
  if (int('total') === undefined && int('calls') === undefined && int('context_max') === undefined) return undefined
  const usage: SessionUsage = {
    input: int('input') ?? 0,
    output: int('output') ?? 0,
    total: int('total') ?? 0,
    calls: int('calls') ?? 0,
    contextEstimated: row.context_estimated === true,
  }
  const set = <K extends keyof SessionUsage>(key: K, read: SessionUsage[K] | undefined) => { if (read !== undefined) usage[key] = read }
  set('reasoning', int('reasoning'))
  set('contextUsed', int('context_used'))
  const max = int('context_max')
  set('contextMax', max !== undefined && max > 0 ? max : undefined)
  set('contextPercent', int('context_percent'))
  set('compressions', int('compressions'))
  set('cacheHitPercent', int('cache_hit_pct'))
  const speed = number(row.avg_tps)
  set('tokensPerSecond', speed !== undefined && speed > 0 ? speed : undefined)
  set('costUSD', number(row.cost_usd))
  const model = row.model
  set('model', typeof model === 'string' && model !== '' ? model : undefined)
  return usage
}

/**
 * `newer`, keeping `older`'s context occupancy when `newer` has none: a resumed runtime
 * reports none until its first turn, which must not blank the gauge.
 */
export function mergeSessionUsage(older: SessionUsage | undefined, newer: SessionUsage): SessionUsage {
  if (!older || newer.contextMax !== undefined) return newer
  const next: SessionUsage = { ...newer, contextEstimated: older.contextEstimated }
  delete next.contextUsed
  delete next.contextPercent
  if (older.contextUsed !== undefined) next.contextUsed = older.contextUsed
  if (older.contextMax !== undefined) next.contextMax = older.contextMax
  if (older.contextPercent !== undefined) next.contextPercent = older.contextPercent
  return next
}

/** `undefined` for a zeroed answer (a runtime without an agent sends `context_max: 0`), which isn't data. */
export function parseContextBreakdown(value: JSONValue | undefined | null): ContextBreakdown | undefined {
  const row = record(value)
  const max = number(row?.context_max)
  if (!row || max === undefined || max <= 0) return undefined
  const categories = (Array.isArray(row.categories) ? row.categories : []).flatMap((entry): ContextCategory[] => {
    const category = record(entry)
    const id = category?.id
    const tokens = number(category?.tokens)
    if (typeof id !== 'string' || tokens === undefined || tokens <= 0) return []
    const label = category?.label
    return [{ id, label: typeof label === 'string' ? label : id, tokens: Math.trunc(tokens) }]
  })
  const breakdown: ContextBreakdown = {
    categories,
    contextMax: Math.trunc(max),
    contextUsed: Math.trunc(number(row.context_used) ?? 0),
    contextPercent: Math.round(number(row.context_percent) ?? 0),
    contextEstimated: typeof row.context_estimated === 'boolean' ? row.context_estimated : true,
  }
  if (typeof row.model === 'string' && row.model !== '') breakdown.model = row.model
  return breakdown
}

/**
 * What the categories leave out of `used` tokens. The occupancy is the provider's count
 * and the categories are estimates that price opaque thinking replays at nothing
 * (`agent/usage_anchor.py`), so the two can part; 0 when the estimates reach it.
 */
export function unitemizedTokens(breakdown: ContextBreakdown, used: number): number {
  return Math.max(0, used - breakdown.categories.reduce((sum, category) => sum + category.tokens, 0))
}

const clampPercent = (value: number): number => Math.min(100, Math.max(0, value))

/**
 * The gauge's numbers. While a turn runs, or with no breakdown read, the usage the
 * gateway streams; otherwise the breakdown, which reports the measured occupancy once
 * there is one and an estimate before (Desktop's `gaugeUsage`).
 */
export function contextGauge(state: { usage?: SessionUsage; breakdown?: ContextBreakdown }, isRunning: boolean): ContextGauge | undefined {
  const { usage, breakdown } = state
  if (!isRunning && breakdown) {
    return { used: breakdown.contextUsed, max: breakdown.contextMax, percent: clampPercent(breakdown.contextPercent),
      isEstimated: breakdown.contextEstimated }
  }
  if (!usage || usage.contextMax === undefined) return undefined
  const used = usage.contextUsed ?? 0
  const percent = usage.contextPercent ?? Math.round(used / usage.contextMax * 100)
  return { used, max: usage.contextMax, percent: clampPercent(percent), isEstimated: usage.contextEstimated }
}

/** 0…1, for the ring. */
export function gaugeFraction(gauge: ContextGauge): number {
  return Math.min(1, Math.max(0, gauge.percent / 100))
}

const compact = new Intl.NumberFormat('en', { notation: 'compact', maximumSignificantDigits: 3 })

/** 950, 12.8K, 1.2M (the Mac's `ContextGaugeText.tokens`). */
export function formatTokens(count: number): string {
  return compact.format(count)
}

/** "30K of 200K tokens (15%)", "~" before an estimate. */
export function contextSummary(gauge: ContextGauge): string {
  return `${gauge.isEstimated ? '~' : ''}${formatTokens(gauge.used)} of ${formatTokens(gauge.max)} tokens (${gauge.percent}%)`
}

export interface SessionUsageView {
  usage?: SessionUsage
  /** What fills its context, as last read (`refresh`). */
  breakdown?: ContextBreakdown
}

/**
 * A chat's token use and context (the usage half of HermesKit's `ChatSession`): fed by
 * the session's events (`observe`), read again by `refresh` when the chat shows, after a
 * turn and after a compression. The gauge (package D) reads it.
 */
export class SessionUsageTracker extends Observable<SessionUsageView> {
  constructor() {
    super({})
  }

  /** A usage object from `session.info`. */
  takeInfo(usage: JSONValue | undefined): void {
    const read = parseSessionUsage(usage)
    if (read) this.take(read)
  }

  /** `message.complete` and `session.usage` carry usage. */
  observe(event: GatewayEvent): void {
    const payload = record(event.payload)
    if (event.type === 'message.complete') {
      const read = parseSessionUsage(payload?.usage)
      if (!read) return
      this.take(read)
      // Measured by this turn: newer than a breakdown read before it.
      if (read.contextMax !== undefined && this.get().breakdown) this.update({ breakdown: undefined })
    } else if (event.type === 'session.usage') {
      // `{usage: {...}}` (`tui_gateway/server.py:2046`).
      const read = parseSessionUsage(payload?.usage)
      if (read) this.take(read)
    }
  }

  private take(read: SessionUsage): void {
    const next = mergeSessionUsage(this.get().usage, read)
    if (JSON.stringify(next) !== JSON.stringify(this.get().usage)) this.update({ usage: next })
  }

  private update(change: Partial<SessionUsageView>): void {
    const next: SessionUsageView = { ...this.get(), ...change }
    for (const key of Object.keys(next) as Array<keyof SessionUsageView>) if (next[key] === undefined) delete next[key]
    this.set(next)
  }

  /**
   * Reads the session's usage and context breakdown again (`session.usage`,
   * `session.context_breakdown`). The breakdown is skipped while a turn runs (its
   * snapshot predates the turn). A failure (an older gateway, a reclaimed runtime) keeps
   * what was read before.
   */
  async refresh(session: ChatSession): Promise<void> {
    if (session.isRuntimeGone) return
    let client
    try {
      client = await session.liveClient()
    } catch {
      return
    }
    const id = session.sessionID
    const params = { session_id: id }
    try {
      const read = parseSessionUsage(await client.call('session.usage', params))
      if (read && id === session.sessionID) this.take(read)
    } catch { /* keep what was read */ }
    if (session.get().isRunning) return
    let answer: JSONValue
    try {
      answer = await client.call('session.context_breakdown', params)
    } catch {
      return
    }
    if (id !== session.sessionID) return
    const breakdown = parseContextBreakdown(answer)
    if (JSON.stringify(breakdown) !== JSON.stringify(this.get().breakdown)) this.update({ breakdown })
  }
}
