import { describeError, hasAvatar, type Bot, type BotActivity, type ServerEntry, type SessionSidebar } from '@talaria/hermes-core'
import { Fragment, useRef, useState } from 'react'
import { useModel, useServers, useSnapshot } from '../../app/hooks.ts'
import { useContextMenu } from '../../ui/ContextMenu.tsx'
import { IconButton } from '../../ui/IconButton.tsx'
import { useMinuteClock } from './age.ts'
import { avatarUpload } from './avatar-image.ts'
import { BotAvatar } from './BotAvatar.tsx'
import { AlertDialog } from './Dialogs.tsx'
import { sessionSidebar } from './sidebar-model.ts'
import styles from './ProfileRail.module.css'

/**
 * The profiles, as the Mac's rail (`ProfileRailView`): a circle each, a rounded square
 * and the pill on the leading edge when selected or hovered; Settings at the bottom.
 * With several servers, each server's profiles in a group of their own, a line between.
 * An avatar's context menu changes or removes its image (Hermes's profile asset, which
 * Hermes Desktop shows too).
 */
export function ProfileRail() {
  const model = useModel()
  const app = useSnapshot(model)
  useServers()
  const servers = model.servers.sidebarServers
  const now = useMinuteClock() / 1000
  const picker = useRef<HTMLInputElement>(null)
  const [target, setTarget] = useState<{ sidebar: SessionSidebar; profile: string }>()
  const [error, setError] = useState<string>()

  const upload = async (file: File | undefined) => {
    if (!file || !target) return
    try {
      await target.sidebar.setAvatar(target.profile, await avatarUpload(file))
    } catch (failure) {
      setError(describeError(failure))
    }
  }

  return (
    <nav className={styles.rail} aria-label="Profiles">
      <div className={styles.items}>
        {servers.map((server, index) => (
          <Fragment key={server.id}>
            {index > 0 && <hr className={styles.divider} />}
            <ServerProfiles server={server} now={now} current={server.id === app.currentServerID}
              named={servers.length > 1}
              onChangeAvatar={(sidebar, profile) => { setTarget({ sidebar, profile }); picker.current?.click() }}
              onError={setError} />
          </Fragment>
        ))}
      </div>
      <div className={styles.footer}>
        <IconButton icon="settings" label="Settings" onClick={() => model.openSettings()} />
      </div>
      <input ref={picker} type="file" accept="image/png,image/jpeg,image/webp,image/gif,image/heic,image/*" hidden
        aria-hidden="true" tabIndex={-1}
        onChange={(event) => {
          const file = event.target.files?.[0]
          event.target.value = ''
          void upload(file)
        }} />
      {error && <AlertDialog title="Couldn’t change the avatar" message={error} onClose={() => setError(undefined)} />}
    </nav>
  )
}

/** One server's profiles. Only the current server's selection shows as selected. */
function ServerProfiles({ server, now, current, named, onChangeAvatar, onError }: {
  server: ServerEntry; now: number; current: boolean; named: boolean
  onChangeAvatar: (sidebar: SessionSidebar, profile: string) => void
  onError: (message: string) => void
}) {
  const model = useModel()
  const snapshot = useSnapshot(server.connection)
  const sidebar = sessionSidebar(model.bridge, server.connection, server.id)
  const kept = useSnapshot(sidebar)
  const connected = snapshot.link.phase === 'connected'
  return (
    <div role="group" aria-label={server.name}>
      {snapshot.bots.map((bot) => (
        <RailItem key={bot.name} bot={bot} image={kept.avatars[bot.name]} activity={activity(sidebar, bot, now)}
          selected={current && bot.name === snapshot.selectedProfile} connected={connected}
          label={named ? `${bot.displayName} — ${server.name}` : bot.displayName}
          onSelect={() => model.selectProfile(server.id, bot.name)}
          onChangeAvatar={() => onChangeAvatar(sidebar, bot.name)}
          onRemoveAvatar={() => void sidebar.removeAvatar(bot.name).catch((failure) => onError(describeError(failure)))} />
      ))}
    </div>
  )
}

/**
 * What the avatar's badge shows: the roster's activity, with what this app sees live
 * (the loudest of the profile's chats, as Desktop's rail rolls them up).
 */
function activity(sidebar: SessionSidebar, bot: Bot, now: number): BotActivity {
  const waiting = sidebar.waitingChats().some((chat) => chat.profile === bot.name)
  const chat = sidebar.botChatStatus(bot.name)
  return bot.activity(now, { waitingForAnswer: waiting || chat === 'waitingForYou', turnRunning: chat === 'working' || chat === 'background' })
}

function RailItem({ bot, image, activity, selected, connected, label, onSelect, onChangeAvatar, onRemoveAvatar }: {
  bot: Bot; image: string | undefined; activity: BotActivity; selected: boolean; connected: boolean; label: string
  onSelect: () => void; onChangeAvatar: () => void; onRemoveAvatar: () => void
}) {
  const [hovered, setHovered] = useState(false)
  const menu = useContextMenu(() => [
    { kind: 'item', id: 'change', label: 'Change Avatar…', icon: 'photo', disabled: !connected },
    ...(hasAvatar(bot) ? [{ kind: 'item' as const, id: 'remove', label: 'Remove Avatar', icon: 'trash' as const, destructive: true, disabled: !connected }] : []),
  ], (id) => (id === 'change' ? onChangeAvatar : onRemoveAvatar)())
  return (
    <>
      <button type="button" className={styles.item} data-selected={selected || undefined} title={label}
        aria-label={label} aria-pressed={selected} onClick={onSelect} onContextMenu={menu.onContextMenu}
        onMouseEnter={() => setHovered(true)} onMouseLeave={() => setHovered(false)}>
        <span className={styles.pill} />
        <BotAvatar bot={bot} activity={activity} squared={selected || hovered || menu.isOpen} image={image} />
      </button>
      {menu.menu}
    </>
  )
}
