import { useConnection } from '../../app/hooks.ts'
import { Icon } from '../../ui/Icon.tsx'
import { openBotChat, openSession } from './SessionList.tsx'
import { useSessionSidebar } from './sidebar-model.ts'
import styles from './Banners.module.css'

/**
 * Over the tabs, on their own card (the Mac's banners): the last row action that
 * failed, with Dismiss, and "N chats waiting for you", which selects the chat that
 * asked first (its profile when no chat is known for it).
 */
export function Banners() {
  const connection = useConnection()
  const store = useSessionSidebar()
  const sidebar = store.get()
  const waiting = store.waitingChats()
  if (!sidebar.actionError && waiting.length === 0) return null
  const openWaiting = () => {
    const chat = waiting[0]
    if (!chat?.profile) return
    if (chat.profile !== connection.get().selectedProfile) connection.selectProfile(chat.profile)
    const row = chat.storedSessionID ? connection.get().sessions[chat.profile]?.find((each) => each.id === chat.storedSessionID) : undefined
    if (chat.isBotChat || !row) openBotChat(connection, store, chat.profile)
    else openSession(connection, store, chat.profile, row)
  }
  return (
    <div className={styles.card}>
      {sidebar.actionError && (
        <div className={styles.error} role="alert">
          <span className={styles.text}>{sidebar.actionError}</span>
          <button type="button" className={styles.dismiss} title="Dismiss" aria-label="Dismiss"
            onClick={() => store.dismissActionError()}><Icon name="close" /></button>
        </div>
      )}
      {waiting.length > 0 && (
        <button type="button" className={styles.waiting} data-testid="waitingChatsBanner"
          onClick={openWaiting}>
          <Icon name="hand" />
          <span className={styles.text}>{waiting.length === 1 ? '1 chat waiting for you' : `${waiting.length} chats waiting for you`}</span>
        </button>
      )}
    </div>
  )
}
