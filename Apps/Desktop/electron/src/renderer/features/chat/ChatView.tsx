import { useLayoutEffect, useRef, useState } from 'react'
import type { ChatSession } from '@talaria/hermes-core'
import { useConnection, useSnapshot } from '../../app/hooks.ts'
import { Composer } from '../composer/Composer.tsx'
import { chatPills, pillRowRoom } from './overlay.ts'
import './registered-pills.ts'
import { ScrollToBottomButton } from './ScrollToBottomButton.tsx'
import { TranscriptList } from './TranscriptList.tsx'
import styles from './ChatView.module.css'

/**
 * One chat (the Mac's `ChatView`): the transcript, and the composer floating over its
 * end with the messages fading under it; the row of pills just above the composer.
 */
export function ChatView({ chat }: { chat: ChatSession }) {
  const connection = useConnection()
  const link = useSnapshot(connection).link
  const view = useSnapshot(chat)
  const composerRow = useRef<HTMLDivElement>(null)
  const [composerHeight, setComposerHeight] = useState(0)
  // J: the registry is fixed at import, so these hooks run in the same order every render.
  const pillsShown = chatPills().map((pill) => pill.useShown?.(chat) ?? false).some(Boolean)
  useLayoutEffect(() => {
    const element = composerRow.current
    const window = element?.ownerDocument.defaultView
    if (!element || !window) return
    const observer = new window.ResizeObserver(() => setComposerHeight(element.offsetHeight))
    observer.observe(element)
    setComposerHeight(element.offsetHeight)
    return () => observer.disconnect()
  }, [])
  return (
    <div className={styles.chat}>
      <TranscriptList chat={chat} view={view} bottomInset={composerHeight} endRoom={pillsShown ? pillRowRoom : 0} overlay={({ awayFromEnd, messagesBelow, scrollToEnd }) => (
        <>
          {chatPills().filter((pill) => pill.order < 100).map(({ id, Pill }) => <Pill key={id} chat={chat} />)}
          {awayFromEnd && <ScrollToBottomButton count={messagesBelow} onClick={scrollToEnd} />}
          {chatPills().filter((pill) => pill.order >= 100).map(({ id, Pill }) => <Pill key={id} chat={chat} />)}
        </>
      )} />
      <div ref={composerRow} className={styles.composerRow}>
        <div className={styles.composerColumn}>
          <Composer chat={chat} composer={connection.chats.composer(chat)} isConnected={link.phase === 'connected'} />
        </div>
      </div>
    </div>
  )
}
