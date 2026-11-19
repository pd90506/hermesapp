import type { Bot } from '@talaria/hermes-core'
import { useEffect, useState } from 'react'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { IconButton } from '../../ui/IconButton.tsx'
import { BotAvatar } from './BotAvatar.tsx'
import styles from './ProfileRail.module.css'

/**
 * The profiles, as the Mac's rail (`ProfileRailView`): a circle each, a rounded square
 * and the pill on the leading edge when selected or hovered; Settings at the bottom.
 */
export function ProfileRail() {
  const model = useModel()
  const snapshot = useSnapshot(model.connection)
  const now = useNow()
  return (
    <nav className={styles.rail} aria-label="Profiles">
      <div className={styles.items}>
        {snapshot.bots.map((bot) => (
          <RailItem key={bot.name} bot={bot} now={now} selected={bot.name === snapshot.selectedProfile}
            onSelect={() => model.connection.selectProfile(bot.name)} />
        ))}
      </div>
      <div className={styles.footer}>
        <IconButton icon="settings" label="Settings" onClick={() => model.showConnectPage(true)} />
      </div>
    </nav>
  )
}

function RailItem({ bot, now, selected, onSelect }: { bot: Bot; now: number; selected: boolean; onSelect: () => void }) {
  const [hovered, setHovered] = useState(false)
  return (
    <button type="button" className={styles.item} data-selected={selected || undefined} title={bot.displayName}
      aria-label={bot.displayName} aria-pressed={selected} onClick={onSelect}
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
