import { isCompressionNote } from '@talaria/hermes-core'
import type { BlockProps } from './registry.ts'
import styles from './MessageBlocks.module.css'
import { MediaMarkdown, UserAttachments } from './media/MediaViews.tsx'

// The renderers package A registers (the Mac's `MessageRow`); replies use B's Markdown.
// C replaces `tool` and adds `work`, G adds the action bars.

/** The user's prompt as typed, in a bubble at the trailing edge. */
export function UserBlock({ block, chat }: BlockProps) {
  if (block.kind !== 'item') return null
  const item = block.item
  const hasText = item.text !== '' || (item.images.length === 0 && item.attachments.length === 0)
  return (
    <div className={styles.userRow}>
      <div className={styles.userColumn}>
        <UserAttachments item={item} chat={chat} />
        {hasText && <div className={styles.bubble}>{item.text}</div>}
        {item.outgoingStatus && <span className={styles.outgoing}>{item.outgoingStatus}</span>}
      </div>
    </div>
  )
}

/** A reply in Markdown (package B); its reasoning is package C's fold. */
export function AssistantBlock({ block, chat }: BlockProps) {
  if (block.kind !== 'item' || block.item.text.trim() === '') return null
  // E: files Hermes delivered (`MEDIA:` tags) show where their tags were.
  return <div className={styles.assistant}><MediaMarkdown text={block.item.text} streaming={block.item.isActive} chat={chat} /></div>
}

/** A line from the app or the gateway; a compression's result centred, as a divider. */
export function SystemBlock({ block }: BlockProps) {
  if (block.kind !== 'item') return null
  const item = block.item
  return <div className={isCompressionNote(item) ? styles.divider : styles.system}>{item.text}</div>
}

/** A tool call, one line, until package C's folds. */
export function ToolBlock({ block }: BlockProps) {
  if (block.kind !== 'item') return null
  const item = block.item
  return (
    <div className={styles.tool} data-active={item.isActive || undefined}>
      <span className={styles.toolName}>{item.toolName ?? 'Tool'}</span>
      {item.detail && <span className={styles.toolDetail}>{item.detail}</span>}
    </div>
  )
}
