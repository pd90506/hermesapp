import {
  bucketTitle, chatStatusLabel, type Bot, type ChatStatus, type GatewayConnection, type SessionSidebar, type SessionSummary,
} from '@talaria/hermes-core'
import { useMemo, useState, useSyncExternalStore } from 'react'
import { useConnection, useModel, useSnapshot } from '../../app/hooks.ts'
import { useContextMenu, type ContextMenuEntry } from '../../ui/ContextMenu.tsx'
import { Icon } from '../../ui/Icon.tsx'
import { localeWeekStart, rowAge, useMinuteClock } from './age.ts'
import { DeleteDialog, RenameDialog } from './Dialogs.tsx'
import { useSessionSidebar } from './sidebar-model.ts'
import styles from './SessionList.module.css'

/**
 * The selected profile's sessions, as the Mac's `SessionListView`: the Bot Chat pinned
 * above the list with a line under it, then the pinned sessions, then the sessions in
 * Desktop's date groups (the newest run under "Sessions", then "Yesterday", "Last
 * week", "September"…), ordered by the user's last prompt. Each row has Pin, Rename…,
 * Fork, Archive and Delete… in its context menu and its "…" button.
 */
export function SessionList() {
  const model = useModel()
  const app = useSnapshot(model)
  const connection = useConnection()
  const snapshot = connection.get()
  const store = useSessionSidebar()
  const sidebar = store.get()
  const active = useActiveChat(connection)
  const now = useMinuteClock()
  const weekStart = useMemo(localeWeekStart, [])
  const [renaming, setRenaming] = useState<SessionSummary>()
  const [deleting, setDeleting] = useState<SessionSummary>()
  const profile = snapshot.selectedProfile
  const bot = snapshot.bots.find((candidate) => candidate.name === profile)
  const rows = profile ? snapshot.sessions[profile] : undefined
  const server = app.currentServerID ?? ''
  const connected = snapshot.link.phase === 'connected'
  // Rebuilt when a read, a pin or the clock changes (`sidebar` is the snapshot).
  const sections = useMemo(() => profile && rows
    ? store.sections(server, profile, rows, { weekStart })
    : { pinned: [], groups: [] }, [store, sidebar, profile, rows, server, now, weekStart])

  const row = (summary: SessionSummary) => profile && (
    <SessionRow key={summary.id} row={summary} profile={profile} now={now} connected={connected}
      selected={active?.kind === 'session' && active.id === summary.id}
      pinned={store.isPinned(server, profile, summary.id)}
      unread={store.isUnread(profile, summary.id)}
      status={store.status(profile, summary.id)}
      date={store.listDate(profile, summary.id)}
      onSelect={() => openSession(connection, store, profile, summary)}
      onAction={(action) => {
        switch (action) {
          case 'pin': store.setPinned(!store.isPinned(server, profile, summary.id), server, profile, summary.id); break
          case 'rename': setRenaming(summary); break
          case 'fork': void store.fork(profile, summary); break
          case 'archive': void store.archive(profile, summary); break
          case 'delete': setDeleting(summary); break
        }
      }} />
  )

  const [head, ...dated] = sections.groups
  return (
    <section className={styles.pane} aria-label="Sessions">
      {bot && <BotChat bot={bot} now={now} status={store.botChatStatus(bot.name)}
        selected={active?.kind === 'bot' && active.profile === bot.name}
        onSelect={() => openBotChat(connection, store, bot.name)} />}
      <div className={styles.list}>
        {sections.pinned.length > 0 && (
          <div role="group" aria-label="Pinned">
            <h2 className={styles.section}>Pinned</h2>
            <div role="list">{sections.pinned.map(row)}</div>
          </div>
        )}
        <div role="group" aria-label="Sessions">
          <h2 className={styles.section}>Sessions</h2>
          {/* Only before the first rows: background refreshes keep the list still. */}
          {!rows && snapshot.sessionListLoading && <p className={styles.note} data-centered>Loading sessions…</p>}
          {snapshot.sessionListError && (
            <p className={styles.note} data-error>
              {snapshot.sessionListError}{' '}
              <button type="button" className={styles.link} onClick={() => void connection.refreshSessionList()}>Retry</button>
            </p>
          )}
          {snapshot.bots.length === 0 && !snapshot.sessionListLoading && (
            <p className={styles.note}>{connected ? 'No profiles available' : 'Connect to browse sessions'}</p>
          )}
          {rows?.length === 0 && !snapshot.sessionListError && <p className={styles.note}>No sessions yet</p>}
          <div role="list">{head?.items.map(row)}</div>
        </div>
        {dated.map((group) => (
          <div key={group.id} role="group" aria-label={group.bucket ? bucketTitle(group.bucket) : ''} data-testid={`sessionDateGroup.${group.id}`}>
            <h2 className={styles.section}>{group.bucket ? bucketTitle(group.bucket) : ''}</h2>
            <div role="list">{group.items.map(row)}</div>
          </div>
        ))}
      </div>
      {renaming && profile && (
        <RenameDialog initial={renaming.title ?? ''} onCancel={() => setRenaming(undefined)}
          onRename={(title) => { setRenaming(undefined); void store.rename(profile, renaming, title) }} />
      )}
      {deleting && profile && (
        <DeleteDialog title={deleting.title?.trim() || 'this chat'} onCancel={() => setDeleting(undefined)}
          onDelete={() => { setDeleting(undefined); void store.delete(profile, deleting) }} />
      )}
    </section>
  )
}

const noSubscription = () => () => {}

/** Which row the chat on screen is (A's chats): the Bot Chat's profile, or a stored session's id. */
export function useActiveChat(connection: GatewayConnection): { kind: 'bot' | 'session'; profile?: string; id?: string } | undefined {
  const chat = useSnapshot(connection.chats).active
  // The chat's own view: a New chat's stored id settles after it opens.
  const view = useSyncExternalStore(chat?.subscribe ?? noSubscription, () => chat?.get())
  if (!view) return undefined
  return view.kind === 'botChat' ? { kind: 'bot', profile: view.profile } : { kind: 'session', id: view.storedSessionID }
}

/** Opens a stored chat, and marks it seen. */
export function openSession(connection: GatewayConnection, sidebar: SessionSidebar, profile: string, row: SessionSummary): void {
  sidebar.select({ kind: 'session', profile, id: row.id })
  void connection.chats.openSession(profile, row).catch(() => {})
}

/** Opens a profile's Bot Chat. */
export function openBotChat(connection: GatewayConnection, sidebar: SessionSidebar, profile: string): void {
  sidebar.select({ kind: 'bot', profile })
  void connection.chats.openBotChat(profile).catch(() => {})
}

/** The Bot Chat pinned above the list (`PinnedBotChat` + `BotRow`): its name and time, then what it is doing or its newest message. */
function BotChat({ bot, now, status, selected, onSelect }: {
  bot: Bot; now: number; status: ChatStatus; selected: boolean; onSelect: () => void
}) {
  const subtitle = status === 'waitingForYou' ? 'Waiting for your answer'
    : status === 'working' || status === 'background' ? (bot.preview ? `Working… ${bot.preview}` : 'Working…')
      : bot.preview ?? (bot.hasChat ? 'No messages yet' : 'Say hello')
  return (
    <div className={styles.bot}>
      <h2 className={styles.section}>Bot Chat</h2>
      <div className={styles.row} role="button" tabIndex={0} aria-pressed={selected} data-selected={selected || undefined}
        data-testid="pinnedBotChat" onClick={onSelect} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') onSelect() }}>
        <span className={styles.line}>
          <span className={styles.title}>{bot.displayName}</span>
          {bot.lastActive && <span className={styles.age}>{rowAge(bot.lastActive * 1000, now)}</span>}
        </span>
        <span className={styles.subtitle} data-waiting={status === 'waitingForYou' || undefined}>{subtitle}</span>
      </div>
      <div className={styles.rule} />
    </div>
  )
}

type RowAction = 'pin' | 'rename' | 'fork' | 'archive' | 'delete'

/**
 * A session (`HistoryRow`): its title (bold while unread) and when the user last wrote
 * in it, or "Waiting for your answer"; at its end the chat's status dot, else the unread
 * dot, then the "…" menu.
 */
function SessionRow({ row, profile, now, connected, selected, pinned, unread, status, date, onSelect, onAction }: {
  row: SessionSummary; profile: string; now: number; connected: boolean; selected: boolean; pinned: boolean
  unread: boolean; status: ChatStatus; date: number | undefined
  onSelect: () => void; onAction: (action: RowAction) => void
}) {
  const title = row.title?.trim() || 'Untitled chat'
  const menu = useContextMenu(() => rowMenu(pinned, connected), (id) => onAction(id as RowAction))
  // The flyout outside the row: events from a portal bubble through React's tree.
  return (<>
    <div className={styles.row} role="listitem" tabIndex={0} aria-selected={selected}
      data-selected={selected || undefined} data-menu-open={menu.isOpen || undefined} data-profile={profile}
      onClick={onSelect} onContextMenu={menu.onContextMenu}
      onKeyDown={(event) => { if (event.key === 'Enter') onSelect() }}>
      <span className={styles.text}>
        <span className={styles.title} data-unread={unread || undefined}>{title}</span>
        {status === 'waitingForYou'
          ? <span className={styles.subtitle} data-waiting data-testid="sessionWaitingText">Waiting for your answer</span>
          : date !== undefined && <span className={styles.age} data-testid="sessionMessageDate">{rowAge(date, now)}</span>}
      </span>
      {status !== 'idle'
        ? <span className={styles.dot} data-status={status} title={chatStatusLabel[status]} aria-label={chatStatusLabel[status]} />
        : unread && <span className={styles.dot} data-status="unread" aria-label="Unread" />}
      <button type="button" className={styles.more} title="More" aria-label="More actions"
        onClick={(event) => { event.stopPropagation(); menu.openBelow(event.currentTarget) }}>
        <Icon name="more" />
      </button>
    </div>
    {menu.menu}
  </>)
}

/** The Mac's `SessionActions`: Pin works offline; the rest need the server. */
export function rowMenu(pinned: boolean, connected: boolean): ContextMenuEntry[] {
  return [
    { kind: 'item', id: 'pin', label: pinned ? 'Unpin' : 'Pin', icon: pinned ? 'unpin' : 'pin' },
    { kind: 'item', id: 'rename', label: 'Rename…', icon: 'rename', disabled: !connected },
    { kind: 'item', id: 'fork', label: 'Fork', icon: 'fork', disabled: !connected },
    { kind: 'item', id: 'archive', label: 'Archive', icon: 'archive', disabled: !connected },
    { kind: 'separator' },
    { kind: 'item', id: 'delete', label: 'Delete…', icon: 'trash', destructive: true, disabled: !connected },
  ]
}
