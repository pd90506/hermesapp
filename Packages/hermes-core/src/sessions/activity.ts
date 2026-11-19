import type { SessionsREST, StoredMessage } from './rest.ts'
import { newestMessage, timelinePage } from './rest.ts'

/**
 * What the session list knows of a row beyond `session.list` (HermesKit's
 * `SessionRowActivity`): when the user last wrote in it, and whether its newest stored
 * message is a reply. Times in epoch milliseconds.
 *
 * `[client choice]` The list is ordered by the user's last prompt, not by the session's
 * last activity (the user, 2026-10-29): with `session.list`'s order, two chats answering
 * at once swapped places with every reply. Neither time is on `session.list` rows.
 */
export interface SessionRowActivity {
  /** The newest prompt the user typed (the timeline), undefined when there is none. */
  lastPrompt?: number
  /** The newest stored message. */
  newestMessage?: number
  /** When the newest stored message is the agent's answer (an assistant row with no tool calls). */
  newestReply?: number
}

/** What a row is ordered, grouped and dated by: its last prompt, else its newest message. */
export function listDate(activity: SessionRowActivity | undefined): number | undefined {
  return activity?.lastPrompt ?? activity?.newestMessage
}

/** Most timeline pages read for one row (500 prompts each). */
const maxTimelinePages = 20

/** A stored time (Unix seconds) as epoch milliseconds: undefined when missing or nonpositive. */
export function storedTime(seconds: number | null | undefined): number | undefined {
  return seconds != null && Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : undefined
}

/** Reads both times. The newest message is required; a timeline that fails leaves `lastPrompt` unset. */
export async function readRowActivity(rest: SessionsREST, sessionID: string, profile: string): Promise<SessionRowActivity> {
  const prompt = lastPrompt(rest, sessionID, profile).catch(() => undefined)
  const newest = await newestMessage(rest, sessionID, profile)
  const activity: SessionRowActivity = {}
  const last = await prompt
  if (last !== undefined) activity.lastPrompt = last
  const time = storedTime(newest?.timestamp)
  if (time !== undefined) activity.newestMessage = time
  if (newest && isReply(newest) && time !== undefined) activity.newestReply = time
  return activity
}

async function lastPrompt(rest: SessionsREST, sessionID: string, profile: string): Promise<number | undefined> {
  let cursor = 0
  let last: number | undefined
  for (let page = 0; page < maxTimelinePages; page++) {
    const answer = await timelinePage(rest, sessionID, profile, cursor)
    const time = storedTime(answer.entries?.at(-1)?.timestamp)
    if (time !== undefined) last = time
    const next = answer.pagination?.next_cursor
    if (answer.pagination?.has_more !== true || next == null || next <= cursor) break
    cursor = next
  }
  return last
}

/** An answer, not a step of a turn still working, nor scaffolding. */
export function isReply(message: StoredMessage): boolean {
  if (message.role !== 'assistant' || message.display_kind === 'hidden') return false
  const calls = message.tool_calls
  return calls == null || (Array.isArray(calls) && calls.length === 0)
}

/**
 * What a read depends on: profile, compression tip, and the tip's stored message count,
 * which every stored message bumps (`hermes_state_messages.py:376-387`). Undefined
 * without a count: such a row is read each time.
 */
export function activityCacheKey(profile: string, row: { id: string; resolved_id?: string | null; message_count?: number | null }): string | undefined {
  if (row.message_count == null) return undefined
  return `${profile}/${row.resolved_id ?? row.id}/${row.message_count}`
}

/**
 * The session list's order: by each row's date, newest first (HermesKit's
 * `SessionListOrder`). A row not read yet keeps its place under the row above it in
 * server order; one leading the list stays at the top.
 */
export function sortByListDate<T>(items: readonly T[], dates: readonly (number | undefined)[]): T[] {
  let above = Infinity
  const keyed = items.map((item, index) => {
    const key = dates[index] ?? above
    above = key
    return { index, key, item }
  })
  return keyed.sort((a, b) => a.key !== b.key ? b.key - a.key : a.index - b.index).map((entry) => entry.item)
}

/**
 * Which replies the user has seen, per session (HermesKit's `SessionReadMarks`): a row
 * whose newest reply is newer than what was seen of it shows as unread until opened.
 * Shared with other devices through Hermes's read watermark (`SessionSidebar`).
 */
export class SessionReadMarks {
  /** Most sessions remembered; the oldest marks go first. */
  static readonly limit = 2000

  constructor(
    /** Seen through, epoch ms, by `profile/id`. */
    private readonly seen: Readonly<Record<string, number>> = {},
    /** When marks started being kept: older replies count as seen. */
    readonly since?: number,
  ) {}

  static key(profile: string, id: string): string {
    return `${profile}/${id}`
  }

  /** Starts keeping marks, once. */
  start(now: number): SessionReadMarks {
    return this.since === undefined ? new SessionReadMarks(this.seen, now) : this
  }

  seenThrough(profile: string, id: string): number | undefined {
    return this.seen[SessionReadMarks.key(profile, id)]
  }

  isUnread(profile: string, id: string, newestReply: number | undefined): boolean {
    if (newestReply === undefined) return false
    const seen = this.seen[SessionReadMarks.key(profile, id)] ?? this.since
    return seen !== undefined && newestReply > seen
  }

  /** Everything up to `time` was seen; the same object when nothing changed. */
  markSeen(profile: string, id: string, time: number): SessionReadMarks {
    const key = SessionReadMarks.key(profile, id)
    if (time <= (this.seen[key] ?? -Infinity)) return this
    let seen: Record<string, number> = { ...this.seen, [key]: time }
    const entries = Object.entries(seen)
    if (entries.length > SessionReadMarks.limit) {
      seen = Object.fromEntries(entries.sort((a, b) => b[1] - a[1]).slice(0, SessionReadMarks.limit))
    }
    return new SessionReadMarks(seen, this.since)
  }

  toJSON(): { seen: Record<string, number>; since?: number } {
    return this.since === undefined ? { seen: { ...this.seen } } : { seen: { ...this.seen }, since: this.since }
  }

  static fromJSON(value: unknown): SessionReadMarks {
    if (!value || typeof value !== 'object') return new SessionReadMarks()
    const { seen, since } = value as { seen?: unknown; since?: unknown }
    const marks: Record<string, number> = {}
    if (seen && typeof seen === 'object') {
      for (const [key, time] of Object.entries(seen)) if (typeof time === 'number') marks[key] = time
    }
    return new SessionReadMarks(marks, typeof since === 'number' ? since : undefined)
  }
}
