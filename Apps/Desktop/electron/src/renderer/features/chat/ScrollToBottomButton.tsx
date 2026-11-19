import { MessagesBelow } from '@talaria/hermes-core'
import styles from './ScrollToBottomButton.module.css'

/**
 * "Scroll to bottom", or how many messages are below ("3 messages"), in a pill just above
 * the composer (the Mac's and Desktop's `ScrollToBottomButton`).
 */
export function ScrollToBottomButton({ count, onClick }: { count: number; onClick: () => void }) {
  return (
    <button type="button" className={styles.pill} onClick={onClick} title={MessagesBelow.scrollToBottom}
      aria-label={MessagesBelow.accessibilityLabel(count)}>
      <svg className={styles.arrow} viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5v11M3.5 9 8 13.5 12.5 9" /></svg>
      <span className={styles.title}>{MessagesBelow.title(count)}</span>
    </button>
  )
}
