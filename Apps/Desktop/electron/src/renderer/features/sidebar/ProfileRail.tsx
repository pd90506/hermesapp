import type { Bot, ServerEntry } from '@talaria/hermes-core'
import { Fragment, useEffect, useState } from 'react'
import { useModel, useServers, useSnapshot } from '../../app/hooks.ts'
import { IconButton } from '../../ui/IconButton.tsx'
import { BotAvatar } from './BotAvatar.tsx'
import styles from './ProfileRail.module.css'

/**
 * The profiles, as the Mac's rail (`ProfileRailView`): a circle each, a rounded square
 * and the pill on the leading edge when selected or hovered; Settings at the bottom.
 * With several servers, each server's profiles in a group of their own, a line between.
 */
export function ProfileRail() {
  const model = useModel()
  const app = useSnapshot(model)
  useServers()
  const servers = model.servers.sidebarServers
  const now = useNow()
  return (
    <nav className={styles.rail} aria-label="Profiles">
      <div className={styles.items}>
        {servers.map((server, index) => (
          <Fragment key={server.id}>
            {index > 0 && <hr className={styles.divider} />}
            <ServerProfiles server={server} now={now} current={server.id === app.currentServerID}
              named={servers.length > 1} />
          </Fragment>
        ))}
      </div>
      <div className={styles.footer}>
        <IconButton icon="settings" label="Settings" onClick={() => model.openSettings()} />
      </div>
    </nav>
  )
}

/** One server's profiles. Only the current server's selection shows as selected. */
function ServerProfiles({ server, now, current, named }: { server: ServerEntry; now: number; current: boolean; named: boolean }) {
  const model = useModel()
  const snapshot = useSnapshot(server.connection)
  return (
    <div role="group" aria-label={server.name}>
      {snapshot.bots.map((bot) => (
        <RailItem key={bot.name} bot={bot} now={now} selected={current && bot.name === snapshot.selectedProfile}
          label={named ? `${bot.displayName} \u2014 ${server.name}` : bot.displayName}
          onSelect={() => model.selectProfile(server.id, bot.name)} />
      ))}
    </div>
  )
}

function RailItem({ bot, now, selected, label, onSelect }: { bot: Bot; now: number; selected: boolean; label: string; onSelect: () => void }) {
  const [hovered, setHovered] = useState(false)
  return (
    <button type="button" className={styles.item} data-selected={selected || undefined} title={label}
      aria-label={label} aria-pressed={selected} onClick={onSelect}
      onMouseEnter={() => setHovered(true)} onMouseLeave={() => setHovered(false)}>
      <span className={styles.pill} />
      <BotAvatar bot={bot} activity={bot.activity(now)} squared={selected || hovered} />
    </button>
  )
}

/** Unix seconds, refreshed each minute: activity badges age out on their own. */
function useNow(): number {
  const [now, setNow] = useState(() => Date.now() / 1000)
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now() / 1000), 60_000)
    return () => clearInterval(timer)
  }, [])
  return now
}
