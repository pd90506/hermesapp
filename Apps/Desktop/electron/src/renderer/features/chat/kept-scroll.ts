import type { VirtualItem } from '@tanstack/react-virtual'
import type { ChatSession } from '@talaria/hermes-core'

/**
 * Where each chat was scrolled when it left the screen (the Mac's `KeptViews`: a chat
 * shown again is where it was): the offset, whether it was at the end, and the rows'
 * measured heights, so it comes back without a jump. Kept while the chat object lives.
 */
export interface KeptScroll {
  offset: number
  atEnd: boolean
  /** The first message on screen and how far below the top it sat. */
  anchor?: { key: string; delta: number }
  measurements: VirtualItem[]
}

const kept = new WeakMap<ChatSession, KeptScroll>()

export function keptScroll(chat: ChatSession): KeptScroll | undefined {
  return kept.get(chat)
}

export function keepScroll(chat: ChatSession, scroll: KeptScroll): void {
  kept.set(chat, scroll)
}
