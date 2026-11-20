import { useCallback, useRef, useState, type ComponentType } from 'react'
import {
  ConversationMarkdown, MessageBranch, OpenSupersededError, branchChat, describeError,
  type ChatSession, type TranscriptItem,
} from '@talaria/hermes-core'
import { useModel } from '../../../app/hooks.ts'
import { useContextMenu, type ContextMenuEntry } from '../../../ui/ContextMenu.tsx'
import { copyText } from '../../markdown/clipboard.ts'
import type { BlockProps } from '../blocks/registry.ts'
import { MessageActionBar } from './MessageActionBar.tsx'
import { useIsInTurnWork } from '../blocks/work/remembered.ts'
import styles from './MessageActions.module.css'

/**
 * A message's right-click menu (the Mac's `copyMenu`): Copy for a selection inside it,
 * then Copy Message (its Markdown source) and Copy Conversation (the loaded chat as
 * Markdown, `ConversationMarkdown.export`).
 */
export function useMessageMenu(item: TranscriptItem, chat: ChatSession) {
  // Read when the menu opens, in the same event: a ref, not state.
  const selection = useRef('')
  const menu = useContextMenu(() => [
    ...(selection.current !== '' ? [{ kind: 'item', id: 'copy', label: 'Copy', icon: 'copy' } as const, { kind: 'separator' } as const] : []),
    { kind: 'item', id: 'message', label: 'Copy Message' },
    { kind: 'item', id: 'conversation', label: 'Copy Conversation' },
  ] satisfies ContextMenuEntry[], (id) => {
    if (id === 'copy') void copyText(selection.current)
    if (id === 'message') void copyText(ConversationMarkdown.messageSource(item))
    if (id === 'conversation') void copyText(ConversationMarkdown.export(chat.get().items))
  })
  const onContextMenu = (event: React.MouseEvent<HTMLElement>) => {
    // A selection within this message (read before the menu takes the focus).
    const selected = event.currentTarget.ownerDocument.getSelection()
    const inside = selected && !selected.isCollapsed && selected.rangeCount > 0 &&
      event.currentTarget.contains(selected.getRangeAt(0).commonAncestorContainer)
    selection.current = inside ? selected.toString() : ''
    menu.onContextMenu(event)
  }
  return { onContextMenu, menu: menu.menu }
}

/** Branch in New Chat from `item` (not for a bot's Bot Chat); a refusal shows in the chat. */
export function useBranch(item: TranscriptItem, chat: ChatSession): (() => void) | undefined {
  const model = useModel()
  if (!MessageBranch.canBranch(chat)) return undefined
  return () => {
    branchChat(model.connection, chat, item).catch((error: unknown) => {
      if (!(error instanceof OpenSupersededError)) chat.showError(describeError(error))
    })
  }
}

/**
 * A message and its action bar as one pointer area (the Mac's `MessageHoverArea`): the
 * bar shows while the pointer is anywhere over the message or the bar, so moving down
 * onto it never hides it. Package C uses this for a turn's answer in its `work` block.
 */
export function MessageWithActions({ item, chat, isNewest, align, children }: {
  item: TranscriptItem
  chat: ChatSession
  isNewest: boolean
  align: 'leading' | 'trailing'
  children: React.ReactNode
}) {
  const { onContextMenu, menu } = useMessageMenu(item, chat)
  const branch = useBranch(item, chat)
  const [menuOpen, setMenuOpen] = useState(false)
  const onMenuOpen = useCallback((open: boolean) => setMenuOpen(open), [])
  // No bar inside a turn's opened work (its commentary), as the Mac's `isInTurnWork`.
  const inTurnWork = useIsInTurnWork()
  const hasBar = !inTurnWork && (item.role === 'user' || ConversationMarkdown.hasActionBar(item))
  return (
    <div className={styles.message} data-menu-open={menuOpen || undefined} onContextMenu={onContextMenu}>
      {children}
      {hasBar && (
        <MessageActionBar item={item} align={align} isNewest={isNewest}
          copy={() => { void copyText(ConversationMarkdown.messageSource(item)) }}
          {...(item.role === 'assistant' && branch ? { branch } : {})} onMenuOpen={onMenuOpen} />
      )}
      {menu}
    </div>
  )
}

/** A prompt or reply renderer with the action bar under it and the copy menu. */
export function withMessageActions(Inner: ComponentType<BlockProps>, align: 'leading' | 'trailing'): ComponentType<BlockProps> {
  function WithActions(props: BlockProps) {
    if (props.block.kind !== 'item') return <Inner {...props} />
    return (
      <MessageWithActions item={props.block.item} chat={props.chat} isNewest={props.isNewest} align={align}>
        <Inner {...props} />
      </MessageWithActions>
    )
  }
  return WithActions
}

/** A tool or system row with the copy menu (no bar, as on the Mac). */
export function withCopyMenu(Inner: ComponentType<BlockProps>): ComponentType<BlockProps> {
  function WithCopyMenu(props: BlockProps) {
    if (props.block.kind !== 'item') return <Inner {...props} />
    return <CopyMenuArea item={props.block.item} chat={props.chat}><Inner {...props} /></CopyMenuArea>
  }
  return WithCopyMenu
}

function CopyMenuArea({ item, chat, children }: { item: TranscriptItem; chat: ChatSession; children: React.ReactNode }) {
  const { onContextMenu, menu } = useMessageMenu(item, chat)
  return <div onContextMenu={onContextMenu}>{children}{menu}</div>
}
