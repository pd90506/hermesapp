import { describeError, hasAvatar, type Bot, type BotActivity } from '@talaria/hermes-core'
import { useRef, useState } from 'react'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import type { AppModel } from '../../app/model.ts'
import { useContextMenu } from '../../ui/ContextMenu.tsx'
import { IconButton } from '../../ui/IconButton.tsx'
import { useMinuteClock } from './age.ts'
import { avatarUpload } from './avatar-image.ts'
import { BotAvatar } from './BotAvatar.tsx'
import { AlertDialog } from './Dialogs.tsx'
import styles from './ProfileRail.module.css'

/**
 * The profiles, as the Mac's rail (`ProfileRailView`): a circle each, a rounded square
 * and the pill on the leading edge when selected or hovered; Settings at the bottom.
 * An avatar's context menu changes or removes its image (Hermes's profile asset, which
 * Hermes Desktop shows too).
 */
export function ProfileRail() {
  const model = useModel()
  const snapshot = useSnapshot(model.connection)
  const sidebar = useSnapshot(model.sidebar)
  const now = useMinuteClock() / 1000
  const picker = useRef<HTMLInputElement>(null)
  const [target, setTarget] = useState<string>()
  const [error, setError] = useState<string>()
  const connected = snapshot.link.phase === 'connected'

  const upload = async (file: File | undefined, profile: string | undefined) => {
    if (!file || !profile) return
    try {
      await model.sidebar.setAvatar(profile, await avatarUpload(file))
    } catch (failure) {
      setError(describeError(failure))
    }
  }

  return (
    <nav className={styles.rail} aria-label="Profiles">
      <div className={styles.items}>
        {snapshot.bots.map((bot) => (
          <RailItem key={bot.name} bot={bot} image={sidebar.avatars[bot.name]} activity={activity(model, bot, now)}
            selected={bot.name === snapshot.selectedProfile} connected={connected}
            onSelect={() => model.connection.selectProfile(bot.name)}
            onChangeAvatar={() => { setTarget(bot.name); picker.current?.click() }}
            onRemoveAvatar={() => void model.sidebar.removeAvatar(bot.name).catch((failure) => setError(describeError(failure)))} />
        ))}
      </div>
      <div className={styles.footer}>
        <IconButton icon="settings" label="Settings" onClick={() => model.showConnectPage(true)} />
      </div>
      <input ref={picker} type="file" accept="image/png,image/jpeg,image/webp,image/gif,image/heic,image/*" hidden
        aria-hidden="true" tabIndex={-1}
        onChange={(event) => {
          const file = event.target.files?.[0]
          event.target.value = ''
          void upload(file, target)
        }} />
      {error && <AlertDialog title="Couldn’t change the avatar" message={error} onClose={() => setError(undefined)} />}
    </nav>
  )
}

/**
 * What the avatar's badge shows: the roster's activity, with what this app sees live
 * (the loudest of the profile's chats, as Desktop's rail rolls them up).
 */
function activity(model: AppModel, bot: Bot, now: number): BotActivity {
  const waiting = model.sidebar.waitingChats().some((chat) => chat.profile === bot.name)
  const chat = model.sidebar.botChatStatus(bot.name)
  return bot.activity(now, { waitingForAnswer: waiting || chat === 'waitingForYou', turnRunning: chat === 'working' || chat === 'background' })
}

function RailItem({ bot, image, activity, selected, connected, onSelect, onChangeAvatar, onRemoveAvatar }: {
  bot: Bot; image: string | undefined; activity: BotActivity; selected: boolean; connected: boolean
  onSelect: () => void; onChangeAvatar: () => void; onRemoveAvatar: () => void
}) {
  const [hovered, setHovered] = useState(false)
  const menu = useContextMenu(() => [
    { kind: 'item', id: 'change', label: 'Change Avatar…', icon: 'photo', disabled: !connected },
    ...(hasAvatar(bot) ? [{ kind: 'item' as const, id: 'remove', label: 'Remove Avatar', icon: 'trash' as const, destructive: true, disabled: !connected }] : []),
  ], (id) => (id === 'change' ? onChangeAvatar : onRemoveAvatar)())
  return (
    <>
      <button type="button" className={styles.item} data-selected={selected || undefined} title={bot.displayName}
        aria-label={bot.displayName} aria-pressed={selected} onClick={onSelect} onContextMenu={menu.onContextMenu}
        onMouseEnter={() => setHovered(true)} onMouseLeave={() => setHovered(false)}>
        <span className={styles.pill} />
        <BotAvatar bot={bot} activity={activity} squared={selected || hovered || menu.isOpen} image={image} />
      </button>
      {menu.menu}
    </>
  )
}
