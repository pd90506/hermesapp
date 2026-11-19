import { useEffect, useState } from 'react'
import { elapsedText, waitingLabel, type ChatSession, type ChatView, type Waiting } from '@talaria/hermes-core'
import { RequestCard } from './RequestCard.tsx'
import styles from './TranscriptFooter.module.css'

/**
 * Under the last message, as the Mac's `TranscriptMessages`: the waiting row while a reply
 * hasn't started, the requests the agent waits on, the turn's status line, the last error.
 */
export function TranscriptFooter({ chat, view }: { chat: ChatSession; view: ChatView }) {
  return (
    <div className={styles.footer}>
      {view.waiting && <WaitingRow waiting={view.waiting} />}
      {view.pendingRequests.map((request) => <RequestCard key={request.id} chat={chat} request={request} />)}
      {!view.waiting && view.isRunning && view.status && <span className={styles.status}>{view.status}</span>}
      {view.lastError && <p className={styles.error} role="alert">{view.lastError}</p>}
    </div>
  )
}

/** "Thinking…" with a breathing square and the time since the prompt (`ResponseWaitingRow`). */
function WaitingRow({ waiting }: { waiting: Waiting }) {
  const [appeared] = useState(() => Date.now())
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [])
  return (
    <div className={styles.waiting} role="status" aria-label="Hermes is responding">
      <span className={styles.pulse} />
      <span className={styles.label}>{waitingLabel(waiting)}</span>
      <span className={styles.elapsed}>{elapsedText(waiting.since ?? appeared, now)}</span>
    </div>
  )
}
