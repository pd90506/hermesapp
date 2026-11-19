import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Icon } from '../../ui/Icon.tsx'
import styles from './Banners.module.css'

/**
 * Over the tabs, on their own card (the Mac's banners): the last row action that
 * failed, with Dismiss, and "N chats waiting for you", which selects the chat that
 * asked first (its profile when no chat is known for it).
 */
export function Banners() {
  const model = useModel()
  const sidebar = useSnapshot(model.sidebar)
  const waiting = model.sidebar.waitingChats()
  if (!sidebar.actionError && waiting.length === 0) return null
  const openWaiting = () => {
    const chat = waiting[0]
    if (!chat?.profile) return
    if (chat.profile !== model.connection.get().selectedProfile) model.connection.selectProfile(chat.profile)
    model.sidebar.select(chat.isBotChat || !chat.storedSessionID
      ? { kind: 'bot', profile: chat.profile }
      : { kind: 'session', profile: chat.profile, id: chat.storedSessionID })
  }
  return (
    <div className={styles.card}>
      {sidebar.actionError && (
        <div className={styles.error} role="alert">
          <span className={styles.text}>{sidebar.actionError}</span>
          <button type="button" className={styles.dismiss} title="Dismiss" aria-label="Dismiss"
            onClick={() => model.sidebar.dismissActionError()}><Icon name="close" /></button>
        </div>
      )}
      {waiting.length > 0 && (
        <button type="button" className={styles.waiting} title="Open the chat waiting for you" data-testid="waitingChatsBanner"
          onClick={openWaiting}>
          <Icon name="hand" />
          <span className={styles.text}>{waiting.length === 1 ? '1 chat waiting for you' : `${waiting.length} chats waiting for you`}</span>
        </button>
      )}
    </div>
  )
}
