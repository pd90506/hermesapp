import type { ComponentType } from 'react'
import type { ChatSession, TranscriptBlock } from '@talaria/hermes-core'

/** What a block renderer gets. */
export interface BlockProps {
  block: TranscriptBlock
  chat: ChatSession
  /** The last user or assistant block: its action bar shows without hover (package G). */
  isNewest: boolean
}

/**
 * Extension point 1 (package A): how each kind of transcript block is drawn.
 *
 * The key is `blockKind(block)` from hermes-core: a row's role (`user`, `assistant`,
 * `system`, `tool`) for an `item` block, else the block's kind (`work`, package C). A
 * package registers its renderer once, at import time, from its own module, and adds one
 * import line to `registered-blocks.ts`; the last registration of a key wins, so B
 * replaces the plain `assistant` renderer with its Markdown one and C adds `work`.
 */
const renderers = new Map<string, ComponentType<BlockProps>>()

export function registerBlockRenderer(kind: string, component: ComponentType<BlockProps>): void {
  renderers.set(kind, component)
}

export function blockRenderer(kind: string): ComponentType<BlockProps> | undefined {
  return renderers.get(kind)
}
