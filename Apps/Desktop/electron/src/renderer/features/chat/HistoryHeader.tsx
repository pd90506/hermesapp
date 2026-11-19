import type { ChatView } from '@talaria/hermes-core'
import styles from './HistoryHeader.module.css'

/**
 * The top of the transcript (the Mac's `HistoryHeader`): a spinner while a page loads or
 * older ones remain, a retry when one failed, the beginning of the conversation.
 */
export function HistoryHeader({ view, retry }: { view: ChatView; retry: () => void }) {
  const load = view.historyLoad
  let content
  switch (load.phase) {
    case 'loadingLatest':
    case 'loadingOlder':
      content = <span className={styles.spinner} role="progressbar" aria-label="Loading" />
      break
    case 'latestFailed':
    case 'olderFailed':
      content = (
        <div className={styles.retry}>
          <span>{load.phase === 'latestFailed' ? 'Couldn’t load messages' : 'Couldn’t load earlier messages'}: {load.message}</span>
          <button type="button" className={styles.retryButton} onClick={retry}>Retry</button>
        </div>
      )
      break
    case 'unavailable':
      content = <span>{load.message}</span>
      break
    case 'idle':
      if (view.paging.hasOlder) content = <span className={styles.spinner} role="progressbar" aria-label="Loading" />
      else if (view.reachedBeginning && view.items.length > 0) content = <span>Beginning of conversation</span>
  }
  return <div className={styles.header}>{content}</div>
}
