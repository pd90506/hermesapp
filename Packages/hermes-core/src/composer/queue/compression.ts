/**
 * `session.compress`'s result (HermesKit's `SessionCompressResult`,
 * `contracts/sessions.py:553-563`). Every field is optional: older gateways send less.
 */
export interface SessionCompressResult {
  /** `compressed` | `aborted` | `pending` (still running on a compute host). */
  status?: string | null
  removed?: number | null
  summary?: {
    noop?: boolean | null
    aborted?: boolean | null
    headline?: string | null
    token_line?: string | null
    note?: string | null
  } | null
  compressed?: boolean | null
  message?: string | null
  info?: unknown
}

const nonEmpty = (text: string | null | undefined): string | undefined => {
  const trimmed = text?.trim()
  return trimmed ? trimmed : undefined
}

/**
 * The line a compression leaves in the chat (HermesKit's `ChatSession.compress`), as
 * Desktop shows it (`use-prompt-actions/slash.ts:684-865`): the summary's headline
 * ("Compressed 120 → 30 messages") with its token line and note; a skipped or pending
 * run says why.
 */
export function compressionMessage(result: SessionCompressResult | null | undefined): string {
  if (result?.status === 'pending') return nonEmpty(result.message) ?? 'compression still running in the background'
  // Another compression holds the lock (`methods_session.py:2160-2163`).
  if (result?.compressed === false && nonEmpty(result.message)) return nonEmpty(result.message)!
  const summary = result?.summary
  const headline = nonEmpty(summary?.headline)
  if (headline) return [headline, nonEmpty(summary?.token_line), nonEmpty(summary?.note)].filter(Boolean).join('\n')
  if (result?.removed && result.removed > 0) return `compressed ${result.removed} messages`
  return 'nothing to compress'
}
