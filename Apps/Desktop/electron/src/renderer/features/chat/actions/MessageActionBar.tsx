import { useEffect, useRef, useState } from 'react'
import { messageTimeDetail, messageTimeText, type TranscriptItem } from '@talaria/hermes-core'
import { Icon } from '../../../ui/Icon.tsx'
import { useContextMenu } from '../../../ui/ContextMenu.tsx'
import styles from './MessageActions.module.css'

/** "Sending…": the time's slot is as wide as it or the time, whichever is wider. */
const sendingText = 'Sending…'

/**
 * The fixed-height row under a message (the Mac's `MessageActionBar`, after ChatGPT's and
 * Desktop's): a small grey Copy, a "…" menu with Branch in New Chat (replies only), and
 * when the message was written, or its sending state in the time's place. It stays in
 * the layout while hidden, so the rows don't move on hover or while the newest streams;
 * it shows on hover over its message, for the newest message, and while a prompt is
 * being sent.
 */
export function MessageActionBar({ item, align, isNewest, copy, branch, onMenuOpen }: {
  item: TranscriptItem
  align: 'leading' | 'trailing'
  isNewest: boolean
  copy: () => void
  /** Branch in New Chat; without it there is no "…" menu. */
  branch?: () => void
  /** Tells the message its menu is open, so its bar stays shown meanwhile. */
  onMenuOpen?: (open: boolean) => void
}) {
  const more = useRef<HTMLButtonElement>(null)
  const menu = useContextMenu(
    () => [{ kind: 'item', id: 'branch', label: 'Branch in New Chat', icon: 'fork' }],
    (id) => { if (id === 'branch') branch?.() },
  )
  useEffect(() => { onMenuOpen?.(menu.isOpen) }, [menu.isOpen, onMenuOpen])
  const status = item.outgoingStatus
  const shown = isNewest || status !== undefined || menu.isOpen
  return (
    <div className={styles.bar} data-align={align} data-shown={shown || undefined} data-message-bar="">
      <button type="button" className={styles.button} title="Copy Message" aria-label="Copy Message" onClick={copy}>
        <Icon name="copy" />
      </button>
      {branch && (
        <button ref={more} type="button" className={styles.button} title="More" aria-label="More actions"
          aria-haspopup="menu" aria-expanded={menu.isOpen} data-open={menu.isOpen || undefined}
          onClick={() => { if (more.current) menu.openBelow(more.current) }}>
          <Icon name="more" />
        </button>
      )}
      {item.timestamp !== undefined
        ? (
          <span className={styles.slot}>
            <span className={styles.reserve} aria-hidden="true">{sendingText}</span>
            {status === undefined
              ? <MessageTime date={new Date(item.timestamp)} />
              : <span className={styles.reserve} aria-hidden="true"><MessageTime date={new Date(item.timestamp)} /></span>}
            {status !== undefined && <span className={styles.status} role="status">{status}</span>}
          </span>
        )
        : status !== undefined && <span className={styles.slot}><span className={styles.status} role="status">{status}</span></span>}
      {menu.menu}
    </div>
  )
}

/** "3:27 PM" today, "Yesterday, 3:27 PM", else "Sep 28, 3:27 PM"; the full date in its tooltip. */
function MessageTime({ date }: { date: Date }) {
  // The day changes at midnight: "3:27 PM" becomes "Yesterday, 3:27 PM" without a reload.
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
    const timer = setTimeout(() => setNow(new Date()), tomorrow.getTime() - now.getTime() + 1000)
    return () => clearTimeout(timer)
  }, [now])
  return <time className={styles.time} dateTime={date.toISOString()} title={messageTimeDetail(date)}>{messageTimeText(date, now)}</time>
}
