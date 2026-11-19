import { useSyncExternalStore } from 'react'
import type { Bot, SessionSummary } from '@talaria/hermes-core'
import { useConnection, useConnectionSnapshot, useSnapshot } from '../../app/hooks.ts'
import styles from './SessionList.module.css'

const noSubscription = () => () => {}

/**
 * The selected profile's sessions, as the Mac's `SessionListView`: the Bot Chat pinned
 * above the list with a line under it, then the sessions (newest first). A click
 * opens the chat; pins, date groups and the row menu come later.
 */
export function SessionList() {
  const snapshot = useConnectionSnapshot()
  const bot = snapshot.bots.find((candidate) => candidate.name === snapshot.selectedProfile)
  const sessions = snapshot.selectedProfile ? snapshot.sessions[snapshot.selectedProfile] : undefined
  return (
    <section className={styles.pane} aria-label="Sessions">
      {bot && <BotChat bot={bot} />}
      <div className={styles.list} role="list">
        <h2 className={styles.section}>Sessions</h2>
        {sessions?.map((session) => <SessionRow key={session.id} session={session} profile={snapshot.selectedProfile!} />)}
        {!sessions && snapshot.sessionListLoading && <p className={styles.note}>Loading…</p>}
        {snapshot.sessionListError && <p className={styles.note}>{snapshot.sessionListError}</p>}
        {sessions?.length === 0 && !snapshot.sessionListError && <p className={styles.note}>No sessions yet</p>}
      </div>
    </section>
  )
}

/** Which row the chat on screen is: the Bot Chat's profile, or a stored session's id. */
function useActiveChat(): { kind: 'bot' | 'session'; profile?: string; id?: string } | undefined {
  const connection = useConnection()
  const chat = useSnapshot(connection.chats).active
  // The chat's own view: a New chat's stored id settles after it opens.
  const view = useSyncExternalStore(chat?.subscribe ?? noSubscription, () => chat?.get())
  if (!view) return undefined
  return view.kind === 'botChat' ? { kind: 'bot', profile: view.profile } : { kind: 'session', id: view.storedSessionID }
}

function BotChat({ bot }: { bot: Bot }) {
  const connection = useConnection()
  const active = useActiveChat()
  const selected = active?.kind === 'bot' && active.profile === bot.name
  return (
    <div className={styles.bot}>
      <h2 className={styles.section}>Bot Chat</h2>
      <div className={styles.row} role="listitem" aria-selected={selected}
        onClick={() => void connection.chats.openBotChat(bot.name).catch(() => {})}>
        <span className={styles.title}>{bot.displayName}</span>
        <span className={styles.subtitle}>{bot.preview ?? 'Say hello'}</span>
      </div>
      <div className={styles.rule} />
    </div>
  )
}

function SessionRow({ session, profile }: { session: SessionSummary; profile: string }) {
  const connection = useConnection()
  const active = useActiveChat()
  const selected = active?.kind === 'session' && active.id === session.id
  const title = session.title?.trim() || 'Untitled chat'
  // The Mac shows the latest stored message's date, once read (`HistoryRow.date`); that
  // read comes with chats. `started_at` is not shown: the list is in last-activity order,
  // so creation times would read out of order.
  return (
    <div className={styles.row} role="listitem" title={title} aria-selected={selected}
      onClick={() => void connection.chats.openSession(profile, session).catch(() => {})}>
      <span className={styles.title}>{title}</span>
    </div>
  )
}
