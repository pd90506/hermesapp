import type { ComponentType } from 'react'
import type { ChatSession } from '@talaria/hermes-core'

/** What a pill gets. */
export interface ChatPillProps {
  chat: ChatSession
}

export interface ChatPill {
  id: string
  /** Left to right; the scroll-to-bottom button is at 100. */
  order: number
  /** Renders nothing (returns null) while it has nothing to show. */
  Pill: ComponentType<ChatPillProps>
}

/**
 * Extension point 3 (package A): pills in the row of the scroll-to-bottom button, just
 * above the composer (the Mac's `ChatPillRow`: the task list, background processes,
 * subagents). Register once at import time and add an import line to
 * `registered-pills.ts`. The row is centred; with a pill showing, the scroll button
 * keeps its place in the row.
 */
const pills: ChatPill[] = []

export function registerChatPill(pill: ChatPill): void {
  const index = pills.findIndex((other) => other.id === pill.id)
  if (index >= 0) pills.splice(index, 1)
  pills.push(pill)
  pills.sort((a, b) => a.order - b.order)
}

export function chatPills(): readonly ChatPill[] {
  return pills
}
