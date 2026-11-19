import { isBlankReply, type TranscriptItem } from './items.ts'
import { backgroundNotice, reviewNote } from './work/notices.ts'
import { groupTurns, type TurnWork } from './work/turn-work.ts'

/**
 * What the chat lists, one row each (HermesKit's `TranscriptBlock`): a message, or a
 * turn's work before its answer folded into one block (package C, `TurnWork`).
 */
export type TranscriptBlock =
  | { kind: 'item'; id: string; item: TranscriptItem }
  | { kind: 'work'; id: string; items: readonly TranscriptItem[]; work: TurnWork }

/**
 * The renderer key of a block (`features/chat/blocks/registry.ts`): a row's role, else
 * `work`; a user row Hermes wrote for finished background work is `backgroundNotice`, a
 * system row of the self-improvement review is `review` (package C).
 */
export function blockKind(block: TranscriptBlock): string {
  if (block.kind === 'work') return 'work'
  const item = block.item
  if (item.role === 'user' && backgroundNotice(item)) return 'backgroundNotice'
  if (item.role === 'system' && reviewNote(item)) return 'review'
  return item.role
}

/** The rows a block holds. */
export function blockItems(block: TranscriptBlock): readonly TranscriptItem[] {
  return block.kind === 'item' ? [block.item] : block.items
}

/**
 * The transcript's rows as blocks (HermesKit's `TranscriptGrouping.blocks`): each turn's
 * work before its answer is one `work` block. A prompt waiting in Hermes's queue is not
 * listed: it waits above the composer (`Transcript.queuedPrompts`).
 */
export function transcriptBlocks(items: readonly TranscriptItem[], isRunning = false): TranscriptBlock[] {
  return groupTurns(items, isRunning).map((block): TranscriptBlock => block.kind === 'item'
    ? { kind: 'item', id: block.item.id, item: block.item }
    : { kind: 'work', id: block.work.id, items: block.work.items, work: block.work })
}

/**
 * The id of the block that draws the row `itemID`, or undefined when none holds it. A
 * work block is named after its first row and an older page can hold earlier rows of
 * the same turn, so a place is kept by a row's id (`TranscriptGrouping.blockID`).
 */
export function blockIDContaining(itemID: string, blocks: readonly TranscriptBlock[]): string | undefined {
  return blocks.find((block) => blockItems(block).some((item) => item.id === itemID))?.id
}

/**
 * How many messages are below the screen, for the scroll-to-bottom button, as Desktop
 * counts them (`use-messages-below.ts`; HermesKit's `MessagesBelow`): a prompt, a reply,
 * a system line. A turn's work and its answer are one reply.
 */
export const MessagesBelow = {
  /** The messages after the last block on screen; zero when none is on screen. */
  count(blocks: readonly TranscriptBlock[], visible: ReadonlySet<string>): number {
    let last = -1
    for (let index = blocks.length - 1; index >= 0; index -= 1) {
      if (visible.has(blocks[index]!.id)) { last = index; break }
    }
    if (last < 0) return 0
    let count = 0
    for (let index = last + 1; index < blocks.length; index += 1) {
      const block = blocks[index]!
      if (block.kind === 'item') {
        if (block.item.role !== 'tool' && !isBlankReply(block.item)) count += 1
      } else {
        const next = blocks[index + 1]
        if (next?.kind === 'item' && next.item.role === 'assistant' && !isBlankReply(next.item)) continue
        count += 1
      }
    }
    return count
  },
  /** "3 messages" with messages below, else "Scroll to bottom". */
  title(count: number): string {
    return count > 0 ? `${count} ${count === 1 ? 'message' : 'messages'}` : MessagesBelow.scrollToBottom
  },
  /** "Scroll to bottom · 3 messages", as Desktop's label. */
  accessibilityLabel(count: number): string {
    return count > 0 ? `${MessagesBelow.scrollToBottom} · ${MessagesBelow.title(count)}` : MessagesBelow.scrollToBottom
  },
  scrollToBottom: 'Scroll to bottom',
} as const

/**
 * How much of a transcript is built at once when it comes on screen, as Desktop's
 * render budget (`thread/list.tsx:106-161`; HermesKit's `PaintBudget`): in characters,
 * roughly what a block costs to lay out. The virtual list uses `weight` to estimate a
 * block's height before it is measured.
 */
export const PaintBudget = {
  firstPaint: 6_000,
  step: 8_000,
  minimumBlocks: 4,
  weight(block: TranscriptBlock): number {
    if (block.kind === 'work') return 150
    const item = block.item
    if (item.role === 'tool') return 400
    let newlines = 0
    for (let index = 0; index < item.text.length; index += 1) if (item.text.charCodeAt(index) === 10) newlines += 1
    return 150 + utf8Length(item.text) + 60 * newlines
  },
  start(blocks: readonly TranscriptBlock[], end: number, budget: number, minimumBlocks = 0): number {
    let start = Math.min(Math.max(end, 0), blocks.length)
    let weight = 0
    while (start > 0 && (weight < budget || end - start < minimumBlocks)) {
      start -= 1
      weight += PaintBudget.weight(blocks[start]!)
    }
    return start
  },
  firstPaintStart(blocks: readonly TranscriptBlock[]): number {
    return PaintBudget.start(blocks, blocks.length, PaintBudget.firstPaint, PaintBudget.minimumBlocks)
  },
} as const

function utf8Length(text: string): number {
  let bytes = 0
  for (const char of text) {
    const code = char.codePointAt(0)!
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4
  }
  return bytes
}

export type MessageDay = 'today' | 'yesterday' | 'earlier'

/**
 * When a message was written, for its timestamp (`formatMessageTimestamp`,
 * `thread/timestamp.ts:42-67`; HermesKit's `MessageTimestamp`): calendar days back from
 * `now`, a time ahead of `now` counting as today.
 */
export function messageDay(date: Date, now: Date = new Date()): MessageDay {
  const start = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  const days = Math.round((start(now) - start(date)) / 86_400_000)
  if (days <= 0) return 'today'
  if (days === 1) return 'yesterday'
  return 'earlier'
}
