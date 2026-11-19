import { messageDay } from './blocks.ts'
import { isQueuedPrompt, type TranscriptItem } from './items.ts'

/**
 * A message's actions (package G; HermesKit's `ConversationMarkdown`): what Copy Message
 * and Copy Conversation put on the clipboard, and which row's action bar stays shown.
 * Only the loaded rows are exported. Reasoning is left out: it is a disclosure beside a
 * reply, not a message of its own.
 */
export const ConversationMarkdown = {
  /** A message's Markdown source; a tool row without text is its name and detail. */
  messageSource(item: TranscriptItem): string {
    if (item.text !== '' || item.role !== 'tool') return item.text
    return [item.toolName, item.detail].filter((part): part is string => part !== undefined).join('\n')
  },

  /** A reply gets an action bar once it has text to copy. */
  hasActionBar(item: TranscriptItem): boolean {
    return item.role === 'assistant' && item.text.trim() !== ''
  },

  /**
   * The row whose action bar stays shown without hover: the last prompt, or reply with
   * text. Tool and system rows have no bar, so a tool call running after a reply leaves
   * the bar on that reply; while a reply is awaited the bar stays on the prompt.
   */
  newestMessageID(items: readonly TranscriptItem[]): string | undefined {
    for (let index = items.length - 1; index >= 0; index -= 1) {
      const item = items[index]!
      if ((item.role === 'user' && !isQueuedPrompt(item)) || ConversationMarkdown.hasActionBar(item)) return item.id
    }
    return undefined
  },

  /** "## User\n\n…" per row, a blank line between them. */
  export(items: readonly TranscriptItem[]): string {
    return items.filter((item) => !isQueuedPrompt(item))
      .map((item) => `## ${roleTitle[item.role]}\n\n${ConversationMarkdown.messageSource(item)}`)
      .join('\n\n')
  },
} as const

const roleTitle = { user: 'User', assistant: 'Assistant', tool: 'Tool', system: 'System' } as const

/**
 * When a message was written, under it (HermesKit's `MessageTimeLabel`, Desktop's
 * `formatMessageTimestamp`): "3:27 PM" today, "Yesterday, 3:27 PM", else
 * "Sep 28, 3:27 PM", in the system's locale.
 */
export function messageTimeText(date: Date, now: Date = new Date(), locale?: string): string {
  const clock = new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }).format(date)
  switch (messageDay(date, now)) {
    case 'today': return clock
    case 'yesterday': return `Yesterday, ${clock}`
    case 'earlier':
      return new Intl.DateTimeFormat(locale, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(date)
  }
}

/** The full date and time, for the time's tooltip: "Thursday, November 19, 2026 at 3:27 PM". */
export function messageTimeDetail(date: Date, locale?: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: 'full', timeStyle: 'short' }).format(date)
}
