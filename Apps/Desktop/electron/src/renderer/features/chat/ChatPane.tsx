import { chatTitle, type ChatSession, type TitledBot } from '@talaria/hermes-core'
import { useConnection, useSnapshot } from '../../app/hooks.ts'
import { ChatView } from './ChatView.tsx'
import styles from './ChatPane.module.css'

/**
 * The chat's side of the window, from the window's top edge as on the Mac; on Windows
 * the caption buttons sit over its top right corner. It shows the chat on screen, a
 * small spinner while one opens (the Mac's `OpeningChatView`), or why nothing shows.
 */
export function ChatPane() {
  const connection = useConnection()
  const { link, bots } = useSnapshot(connection)
  const chats = useSnapshot(connection.chats)
  const title = chats.opening ? chatTitle(chats.opening, bots, true) : chats.active ? <ActiveTitle chat={chats.active} bots={bots} /> : null
  return (
    <main className={styles.pane}>
      <header className={styles.band}>{title && <h1 className={styles.title}>{title}</h1>}</header>
      {chats.opening
        ? <Opening title={chatTitle(chats.opening, bots, true)} />
        : chats.active
          ? <ChatView key={chatKey(chats.active)} chat={chats.active} />
          : (
            <div className={styles.empty}>
              {link.phase === 'failed'
                ? <p className={styles.message} role="alert">{link.message}</p>
                : chats.openError
                  ? <p className={styles.message} role="alert">{chats.openError}</p>
                  : (
                    <div className={styles.placeholder}>
                      <p className={styles.heading}>No Chat Selected</p>
                      <p className={styles.message}>Pick a profile, then a session to chat with.</p>
                    </div>
                  )}
            </div>
          )}
    </main>
  )
}

const keys = new WeakMap<ChatSession, number>()
let nextKey = 0

/** One key per chat object, so each chat keeps its own list and composer state. */
function chatKey(chat: ChatSession): number {
  let key = keys.get(chat)
  if (key === undefined) {
    key = ++nextKey
    keys.set(chat, key)
  }
  return key
}

/** The chat's title, kept up as the chat renames itself. */
function ActiveTitle({ chat, bots }: { chat: ChatSession; bots: readonly TitledBot[] }) {
  return chatTitle(useSnapshot(chat), bots)
}

function Opening({ title }: { title: string }) {
  return (
    <div className={styles.empty}>
      <span className={styles.spinner} role="progressbar" aria-label={`Opening ${title}`} />
    </div>
  )
}
