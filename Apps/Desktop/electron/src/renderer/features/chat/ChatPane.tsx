import type { ChatSession, PendingChat } from '@talaria/hermes-core'
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
  const link = useSnapshot(connection).link
  const chats = useSnapshot(connection.chats)
  return (
    <main className={styles.pane}>
      <div className={styles.band} />
      {chats.opening
        ? <Opening pending={chats.opening} bots={connection.get().bots} />
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

/** The Mac's `title(of opening:)`: the bot's name, or "title · bot" for a side chat. */
function openingTitle(pending: PendingChat, bots: readonly { name: string; displayName: string }[]): string {
  const bot = bots.find((candidate) => candidate.name === pending.profile)?.displayName ?? pending.profile ?? 'Hermes'
  if (pending.kind === 'botChat') return bot
  return `${pending.title?.trim() || 'Side chat'} · ${bot}`
}

function Opening({ pending, bots }: { pending: PendingChat; bots: readonly { name: string; displayName: string }[] }) {
  return (
    <div className={styles.empty}>
      <span className={styles.spinner} role="progressbar" aria-label={`Opening ${openingTitle(pending, bots)}`} />
    </div>
  )
}
