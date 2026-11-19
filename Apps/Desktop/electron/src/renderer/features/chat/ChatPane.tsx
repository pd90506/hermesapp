import { useModel, useSnapshot } from '../../app/hooks.ts'
import styles from './ChatPane.module.css'

/**
 * The chat's side of the window, from the window's top edge as on the Mac; on Windows
 * the caption buttons sit over its top right corner. Chats open here in the next change.
 */
export function ChatPane() {
  const model = useModel()
  const connection = useSnapshot(model.connection)
  const message = connection.link.phase === 'failed'
    ? connection.link.message
    : connection.bots.length > 0 ? 'Chats open here in a later version.' : ''
  return (
    <main className={styles.pane}>
      <div className={styles.band} />
      <div className={styles.empty}>
        <p className={styles.message} role={connection.link.phase === 'failed' ? 'alert' : undefined}>{message}</p>
      </div>
    </main>
  )
}
