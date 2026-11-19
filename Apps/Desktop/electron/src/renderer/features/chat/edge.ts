import type { ComponentType } from 'react'
import type { ChatSession, ChatView, TranscriptBlock } from '@talaria/hermes-core'

/** What a chat-edge component gets from the transcript list. */
export interface ChatEdgeProps {
  chat: ChatSession
  view: ChatView
  /** The blocks the list draws, oldest first. */
  blocks: readonly TranscriptBlock[]
  /** The ids of the blocks on screen (above the composer). */
  visible: ReadonlySet<string>
  /** The list is at (or near) its end. */
  atEnd: boolean
  /** The composer row's height, which floats over the list's end. */
  bottomInset: number
  /** Scrolls the block to the top of the list. */
  scrollToBlock(id: string): void
  /** Calls `listener` when the user scrolls the list (wheel, touch, keys, the scroller). */
  onUserScroll(listener: () => void): () => void
}

export interface ChatEdge {
  id: string
  Edge: ComponentType<ChatEdgeProps>
}

/**
 * Extension point 4 (added by package G): things drawn at the transcript's trailing
 * edge, over the room the column leaves there (`--chat-side-room`): the prompt rail.
 * Register once at import time and add an import line to `registered-edges.ts`.
 */
const edges: ChatEdge[] = []

export function registerChatEdge(edge: ChatEdge): void {
  const index = edges.findIndex((other) => other.id === edge.id)
  if (index >= 0) edges.splice(index, 1)
  edges.push(edge)
}

export function chatEdges(): readonly ChatEdge[] {
  return edges
}
