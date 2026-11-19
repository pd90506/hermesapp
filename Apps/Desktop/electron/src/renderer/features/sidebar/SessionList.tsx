import type { Bot, SessionSummary } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { relativeTime } from '../../app/time.ts'
import styles from './SessionList.module.css'

/**
 * The selected profile's sessions, as the Mac's `SessionListView`: the Bot Chat pinned
 * above the list with a line under it, then the sessions (newest first). Opening a
 * chat, pins, date groups and the row menu come with chats.
 */
export function SessionList() {
  const model = useModel()
  const snapshot = useSnapshot(model.connection)
  const bot = snapshot.bots.find((candidate) => candidate.name === snapshot.selectedProfile)
  const sessions = snapshot.selectedProfile ? snapshot.sessions[snapshot.selectedProfile] : undefined
  return (
    <section className={styles.pane} aria-label="Sessions">
      {bot && <BotChat bot={bot} />}
      <div className={styles.list} role="list">
        <h2 className={styles.section}>Sessions</h2>
        {sessions?.map((session) => <SessionRow key={session.id} session={session} />)}
        {!sessions && snapshot.sessionListLoading && <p className={styles.note}>Loading…</p>}
        {snapshot.sessionListError && <p className={styles.note}>{snapshot.sessionListError}</p>}
        {sessions?.length === 0 && !snapshot.sessionListError && <p className={styles.note}>No sessions yet</p>}
      </div>
    </section>
  )
}

function BotChat({ bot }: { bot: Bot }) {
  return (
    <div className={styles.bot}>
      <h2 className={styles.section}>Bot Chat</h2>
      <div className={styles.row} role="listitem">
        <span className={styles.title}>{bot.displayName}</span>
        <span className={styles.subtitle}>{bot.preview ?? 'Say hello'}</span>
      </div>
      <div className={styles.rule} />
    </div>
  )
}

function SessionRow({ session }: { session: SessionSummary }) {
  const title = session.title?.trim() || 'Untitled chat'
  const started = session.started_at ? new Date(session.started_at * 1000) : undefined
  return (
    <div className={styles.row} role="listitem" title={title}>
      <span className={styles.title}>{title}</span>
      {started && <span className={styles.subtitle}>{relativeTime(started)}</span>}
    </div>
  )
}
