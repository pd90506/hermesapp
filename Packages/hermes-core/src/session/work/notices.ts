import { reviewDisplayKind, type TranscriptItem } from '../items.ts'

/**
 * A message Hermes writes into the chat as a user turn when background work ends: a
 * background process finished, matched a watch pattern or sent a heartbeat, or an async
 * subagent finished (`format_process_notification`). Not something the user typed, so
 * the chat shows it as a compact line, as Desktop does (`ProcessNotificationNote`;
 * HermesKit's `BackgroundNotice`).
 */
export interface BackgroundNotice {
  /** The first line, without the `[IMPORTANT: …]` wrapper. */
  headline: string
  /** The rest: command, output, result. */
  detail: string
}

/** Hermes's own test for these prompts (`_SYNTHETIC_PROMPT`), plus Desktop's legacy heartbeat rows. */
const noticePattern = /^\s*(?:\[IMPORTANT: Background process |\[ASYNC (?:DELEGATION )?(?:BATCH )?COMPLETE\b|A background fan-out of \d+ subagent\(s\) you dispatched earlier has finished\.|A background subagent you dispatched earlier has finished\.|\[Background process \S+ heartbeat #\d+ )/i

export function parseBackgroundNotice(text: string): BackgroundNotice | undefined {
  if (!noticePattern.test(text)) return undefined
  let body = text.trim()
  if (body.startsWith('[IMPORTANT:')) {
    body = body.slice('[IMPORTANT:'.length)
    if (body.endsWith(']')) body = body.slice(0, -1)
  } else if (body.startsWith('[Background process') && body.endsWith(']')) {
    body = body.slice(1, -1)
  }
  body = body.trim()
  const newline = body.indexOf('\n')
  const headline = (newline < 0 ? body : body.slice(0, newline)).replace(/^[ \t]+|[ \t]+$/g, '')
  const detail = newline < 0 ? '' : body.slice(newline + 1).trim()
  return { headline, detail }
}

/** A user row Hermes wrote for finished background work. */
export function backgroundNotice(item: TranscriptItem): BackgroundNotice | undefined {
  return item.role === 'user' ? parseBackgroundNotice(item.text) : undefined
}

/**
 * What the self-improvement review saved after a turn (`review.summary`; HermesKit's
 * `ReviewNote`): "💾 Self-improvement review: Memory updated · Skill 'x' patched".
 * Desktop shows it as a line split at the first colon into a label and its detail.
 */
export interface ReviewNote {
  /** "Self-improvement review". */
  label: string
  /** "Memory updated · Skill 'x' patched"; may be empty. */
  detail: string
}

/** The summary without its leading glyph (everything before the first letter or digit); undefined when nothing is left. */
export function reviewNoteText(summary: string): string | undefined {
  const text = summary.trim()
  const start = text.search(/[\p{L}\p{Nd}]/u)
  return start < 0 ? undefined : text.slice(start)
}

/** The label runs to the first colon or line break; the rest is the detail. */
export function parseReviewNote(shown: string): ReviewNote | undefined {
  const end = shown.search(/[:\n\r]/)
  const label = (end < 0 ? shown : shown.slice(0, end)).replace(/^[ \t]+|[ \t]+$/g, '')
  if (label === '') return undefined
  let rest = end < 0 ? '' : shown.slice(end)
  if (rest.startsWith(':')) rest = rest.slice(1)
  return { label, detail: rest.trim() }
}

/** A system row the self-improvement review wrote. */
export function reviewNote(item: TranscriptItem): ReviewNote | undefined {
  return item.role === 'system' && item.displayKind === reviewDisplayKind
    ? parseReviewNote(reviewNoteText(item.text) ?? '')
    : undefined
}
