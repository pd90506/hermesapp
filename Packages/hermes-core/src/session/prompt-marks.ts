import { blockItems, type TranscriptBlock } from './blocks.ts'
import { isQueuedPrompt, type TranscriptItem } from './items.ts'

/**
 * A prompt the user sent, as the chat's prompt rail marks it (package G; HermesKit's
 * `PromptMark`): a tick at the chat's edge whose label is the prompt, and which scrolls
 * the chat to it.
 */
export interface PromptMark {
  /** The user row's id. */
  id: string
  /** The prompt's first line, cut to `PromptMarks.labelLimit` characters. */
  label: string
}

/** The longest label, ellipsis included. */
const labelLimit = 60

export const PromptMarks = {
  labelLimit,

  /** The prompts of `items`, oldest first. A prompt waiting in Hermes's queue has none. */
  marks(items: readonly TranscriptItem[]): PromptMark[] {
    const marks: PromptMark[] = []
    for (const item of items) {
      if (item.role === 'user' && !isQueuedPrompt(item)) marks.push({ id: item.id, label: PromptMarks.label(item) })
    }
    return marks
  },

  /**
   * The first line of the prompt with text, its spaces collapsed, cut to `limit`. A
   * prompt with only files or images is labelled with what it carried.
   */
  label(item: TranscriptItem, limit: number = labelLimit): string {
    const line = item.text.split(/\r\n|\r|\n/).map((part) => part.split(/\s+/).filter(Boolean).join(' ')).find((part) => part !== '')
    if (line === undefined) {
      if (item.attachments.length > 0) return cut(item.attachments.join(', '), limit)
      return item.images.length > 1 ? `${item.images.length} images` : 'Image'
    }
    return cut(line, limit)
  },

  /**
   * The prompt the chat is at with the blocks `visible` on screen: the last prompt in or
   * above the first block on screen, or the first prompt when that block is above them all.
   * - A chat scrolled to its end (`atEnd`) is at its last prompt, even when the reply
   *   before it still fills the top of the screen.
   * - A prompt `picked` on the rail is the one the chat is at while the pick holds
   *   (`PromptPick`), whatever else is on screen.
   */
  current(blocks: readonly TranscriptBlock[], marks: readonly PromptMark[], visible: ReadonlySet<string>,
    atEnd = false, picked?: string): string | undefined {
    const first = marks[0]
    if (!first) return undefined
    if (picked !== undefined && marks.some((mark) => mark.id === picked)) return picked
    const top = blocks.find((block) => visible.has(block.id))?.id
    if (top === undefined) return undefined
    if (atEnd) return marks.at(-1)!.id
    const ids = new Set(marks.map((mark) => mark.id))
    let current: string | undefined
    for (const block of blocks) {
      const prompt = [...blockItems(block)].reverse().find((item) => ids.has(item.id))
      if (prompt) current = prompt.id
      if (block.id === top) return current ?? first.id
    }
    return undefined
  },

  /** The id of the block that draws the row `itemID`. */
  blockID(blocks: readonly TranscriptBlock[], itemID: string): string | undefined {
    return blocks.find((block) => blockItems(block).some((item) => item.id === itemID))?.id
  },
} as const

function cut(text: string, limit: number): string {
  const chars = [...text]
  if (chars.length <= limit) return text
  return chars.slice(0, Math.max(limit - 1, 0)).join('').trim() + '…'
}

/**
 * A prompt picked on the rail (a tick or a row of its panel; HermesKit's `PromptPick`). The
 * chat is at that prompt until the user scrolls it away: the pick holds until the prompt's
 * block, once on screen, leaves it. The jump lands after the pick, so a block not on
 * screen yet does not end it. The app also ends it when the user scrolls or sends.
 */
export interface PromptPick {
  readonly promptID: string
  /** Whether the prompt's block has been on screen since the pick. */
  readonly wasShown: boolean
}

export const PromptPicks = {
  pick(promptID: string): PromptPick {
    return { promptID, wasShown: false }
  },
  /** The pick with the blocks `visible` on screen; undefined once it no longer holds. */
  holding(pick: PromptPick, visible: ReadonlySet<string>, blocks: readonly TranscriptBlock[]): PromptPick | undefined {
    const block = PromptMarks.blockID(blocks, pick.promptID)
    if (block === undefined) return undefined
    if (visible.has(block)) return pick.wasShown ? pick : { ...pick, wasShown: true }
    return pick.wasShown ? undefined : pick
  },
} as const
