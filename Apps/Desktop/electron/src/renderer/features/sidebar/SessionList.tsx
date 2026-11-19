import {
  bucketTitle, chatStatusLabel, type Bot, type ChatStatus, type SessionSummary, type SidebarSelection,
} from '@talaria/hermes-core'
import { useMemo, useState } from 'react'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { useContextMenu, type ContextMenuEntry } from '../../ui/ContextMenu.tsx'
import { Icon } from '../../ui/Icon.tsx'
import { localeWeekStart, rowAge, useMinuteClock } from './age.ts'
import { DeleteDialog, RenameDialog } from './Dialogs.tsx'
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
  const snapshot = useSnapshot(model.connection)
  const sidebar = useSnapshot(model.sidebar)
  const now = useMinuteClock()
  const weekStart = useMemo(localeWeekStart, [])
  const [renaming, setRenaming] = useState<SessionSummary>()
  const [deleting, setDeleting] = useState<SessionSummary>()
  const profile = snapshot.selectedProfile
  const bot = snapshot.bots.find((candidate) => candidate.name === profile)
  const rows = profile ? snapshot.sessions[profile] : undefined
  const server = app.server?.serverURL ?? ''
  const connected = snapshot.link.phase === 'connected'
  // Rebuilt when a read, a pin or the clock changes (`sidebar` is the snapshot).
  const sections = useMemo(() => profile && rows
    ? model.sidebar.sections(server, profile, rows, { weekStart })
    : { pinned: [], groups: [] }, [model.sidebar, sidebar, profile, rows, server, now, weekStart])
  const selection = sidebar.selection

  const row = (summary: SessionSummary) => profile && (
    <SessionRow key={summary.id} row={summary} profile={profile} now={now} connected={connected}
      selected={selection?.kind === 'session' && selection.profile === profile && selection.id === summary.id}
      pinned={model.sidebar.isPinned(server, profile, summary.id)}
      unread={model.sidebar.isUnread(profile, summary.id)}
      status={model.sidebar.status(profile, summary.id)}
      date={model.sidebar.listDate(profile, summary.id)}
      onSelect={() => model.sidebar.select({ kind: 'session', profile, id: summary.id })}
      onAction={(action) => {
        switch (action) {
          case 'pin': model.sidebar.setPinned(!model.sidebar.isPinned(server, profile, summary.id), server, profile, summary.id); break
          case 'rename': setRenaming(summary); break
          case 'fork': void model.sidebar.fork(profile, summary); break
          case 'archive': void model.sidebar.archive(profile, summary); break
          case 'delete': setDeleting(summary); break
        }
      }} />
  )

  const [head, ...dated] = sections.groups
  return (
    <section className={styles.pane} aria-label="Sessions">
      {bot && <BotChat bot={bot} now={now} status={model.sidebar.botChatStatus(bot.name)}
        selected={selection?.kind === 'bot' && selection.profile === bot.name}
        onSelect={() => model.sidebar.select({ kind: 'bot', profile: bot.name } satisfies SidebarSelection)} />}
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
              <button type="button" className={styles.link} onClick={() => void model.connection.refreshSessionList()}>Retry</button>
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
          onRename={(title) => { setRenaming(undefined); void model.sidebar.rename(profile, renaming, title) }} />
      )}
      {deleting && profile && (
        <DeleteDialog title={deleting.title?.trim() || 'this chat'} onCancel={() => setDeleting(undefined)}
          onDelete={() => { setDeleting(undefined); void model.sidebar.delete(profile, deleting) }} />
      )}
    </section>
  )
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
