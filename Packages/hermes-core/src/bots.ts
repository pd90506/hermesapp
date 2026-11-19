import type { JSONValue } from './protocol/jsonrpc.ts'

// `profiles.list` rows (`tui_gateway/methods_profiles.py:281-302`) and session rows
// (`session.list`). Everything except the ids is optional, as HermesKit decodes them,
// so older and newer gateways still work.

export interface ProfileSessionPreview {
  id: string
  title?: string | null
  preview?: string | null
  started_at?: number | null
  last_active?: number | null
  message_count?: number | null
}

export interface ProfileWorkerSession {
  id: string
  source?: string | null
  title?: string | null
  /** Heartbeated at least every 60 s while the worker runs. */
  last_active?: number | null
}

/** The profile's Bot Chat registry row; `resolved_id` is the live compression tip. */
export interface ProfileCanonicalSession {
  id: string
  resolved_id?: string | null
  root_title?: string | null
  title?: string | null
  preview?: string | null
  started_at?: number | null
  last_active?: number | null
  message_count?: number | null
  live_message_count?: number | null
}

export interface ProfileRow {
  name: string
  is_default?: boolean | null
  model?: string | null
  provider?: string | null
  description?: string | null
  display_name?: string | null
  last_session?: ProfileSessionPreview | null
  worker_session?: ProfileWorkerSession | null
  canonical_session?: ProfileCanonicalSession | null
  ui_meta?: Record<string, JSONValue> | null
  has_avatar?: boolean | null
}

export interface SessionSummary {
  /** The stored session id. */
  id: string
  resolved_id?: string | null
  title?: string | null
  preview?: string | null
  /** Unix seconds. */
  started_at?: number | null
  message_count?: number | null
  live_message_count?: number | null
  source?: string | null
  /** The lineage root's title, when the gateway sends it. */
  root_title?: string | null
}

/** The canonical chat's title (`canonical-chat.ts:50`). */
export const botChatTitle = 'Bot Chat'
/** Hermes Desktop's "active now" window for the Bot Chat (`row-helpers.ts:55-57`), seconds. */
export const botActiveWindow = 90
/** Workers heartbeat at least every 60 s; one missed beat is bridged (`row-helpers.ts:72-86`). */
export const botWorkerWindow = 150

export type BotActivity = 'idle' | 'recent' | 'working' | 'waitingForYou'

/**
 * One bot in the sidebar: a Hermes profile and its one permanent chat (HermesKit's `Bot`,
 * after Hermes Desktop's Bot Mode). The chat's only identity is (profile, session titled
 * exactly "Bot Chat"); the canonical ids are the server's current answer, used to
 * recognise that chat in listings, never as the target of an open.
 */
export class Bot {
  constructor(readonly profile: ProfileRow) {}

  get name(): string {
    return this.profile.name
  }

  get isDefault(): boolean {
    return this.profile.is_default === true || this.profile.name === 'default'
  }

  /**
   * In Desktop's order (`plugins/hermes-bots/labels.ts:45-75`): the Bot Mode title in
   * `ui_meta`, the profile's display name, "Hermes" for `default`, then the name with
   * `-`/`_` as spaces, each word capitalised.
   */
  get displayName(): string {
    const meta = this.profile.ui_meta?.['hermes-bots']
    const title = meta && typeof meta === 'object' && !Array.isArray(meta) ? meta.title : undefined
    if (typeof title === 'string' && title.trim()) return title.trim()
    const display = this.profile.display_name?.trim()
    if (display) return display
    if (this.profile.name.toLowerCase() === 'default') return 'Hermes'
    return this.profile.name.replace(/[-_]+/g, ' ').trim().split(' ').filter(Boolean)
      .map((word) => word.slice(0, 1).toUpperCase() + word.slice(1)).join(' ')
  }

  /** The Bot Chat's newest message, or undefined before the bot has a chat. */
  get preview(): string | undefined {
    return this.profile.canonical_session?.preview?.trim() || undefined
  }

  /** Last activity of the Bot Chat, Unix seconds. */
  get lastActive(): number | undefined {
    const seconds = this.profile.canonical_session?.last_active
    return seconds && seconds > 0 ? seconds : undefined
  }

  get hasChat(): boolean {
    return this.profile.canonical_session != null
  }

  /** Stored ids the Bot Chat answers to right now: registry row and lineage tip. */
  get chatStoredIDs(): Set<string> {
    const canonical = this.profile.canonical_session
    if (!canonical) return new Set()
    return new Set([canonical.id, canonical.resolved_id].filter((id): id is string => !!id))
  }

  /** Roster-only activity; the live parts come with chats in a later change. */
  activity(nowSeconds: number, live: { turnRunning?: boolean; waitingForAnswer?: boolean } = {}): BotActivity {
    if (live.waitingForAnswer) return 'waitingForYou'
    if (live.turnRunning) return 'working'
    const beat = this.profile.worker_session?.last_active
    if (beat && beat > 0 && nowSeconds - beat < botWorkerWindow) return 'working'
    const last = this.lastActive
    if (last !== undefined && nowSeconds - last < botActiveWindow) return 'recent'
    return 'idle'
  }

  /** `default` first, then the server's order. */
  static roster(profiles: readonly ProfileRow[]): Bot[] {
    const bots = profiles.map((profile) => new Bot(profile))
    return [...bots.filter((bot) => bot.isDefault), ...bots.filter((bot) => !bot.isDefault)]
  }

  /**
   * Is this listing row the Bot Chat registry row? `root_title` wins when the gateway
   * reports it, plain `title` otherwise (`canonical-chat.ts:196-204`).
   */
  static isChatRow(row: SessionSummary): boolean {
    const rootTitle = (row.root_title ?? '').trim()
    return rootTitle === botChatTitle || (rootTitle === '' && (row.title ?? '').trim() === botChatTitle)
  }

  /** A Bot Chat is never a History row, even when a listing shows it. */
  static isBotChat(row: SessionSummary, bot: Bot | undefined): boolean {
    if (Bot.isChatRow(row)) return true
    if (!bot) return false
    const ids = bot.chatStoredIDs
    return ids.has(row.id) || (!!row.resolved_id && ids.has(row.resolved_id))
  }
}

/**
 * The only sources the session list shows: the app's own (`desktop`) and the terminal's
 * (`tui`), plus rows without a source (decided by the user, 2026-10-29; HermesKit's
 * `SessionSourceSettings.listedSources`).
 */
export const listedSources = ['desktop', 'tui'] as const

/** The gateway compares sources lowercased (`methods_session.py:142`). */
export function normalizedSource(source: string | null | undefined): string | undefined {
  const value = source?.trim().toLowerCase()
  return value ? value : undefined
}

export function isListedSource(source: string | null | undefined): boolean {
  const value = normalizedSource(source)
  return value === undefined || (listedSources as readonly string[]).includes(value)
}

/** A profile's session list: listed sources only, never the bot's own chat. */
export function historyRows(rows: readonly SessionSummary[], bot: Bot | undefined): SessionSummary[] {
  return rows.filter((row) => isListedSource(row.source) && !Bot.isBotChat(row, bot))
}
