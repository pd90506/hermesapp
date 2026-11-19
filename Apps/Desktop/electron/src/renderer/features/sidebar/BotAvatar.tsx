import type { Bot, BotActivity } from '@talaria/hermes-core'
import styles from './BotAvatar.module.css'
import { fallbackColor, initials } from './avatar.ts'

/**
 * A profile's avatar, as the Mac's `BotAvatar`: its initials in white on its colour
 * (one of eight, by its name), a circle that turns into a rounded square when selected
 * or hovered, and the badge of what it is doing. Avatar images come with the avatar menu.
 */
export function BotAvatar({ bot, activity, squared }: { bot: Bot; activity: BotActivity; squared: boolean }) {
  const name = bot.displayName
  return (
    <span className={styles.avatar} data-squared={squared || undefined}>
      <span className={styles.face} style={{ '--avatar-color': fallbackColor(name) } as React.CSSProperties}>
        {initials(name)}
      </span>
      {activity !== 'idle' && <span className={styles.badge} data-activity={activity} aria-label={badgeLabel[activity]} />}
    </span>
  )
}

const badgeLabel: Record<BotActivity, string> = {
  idle: '',
  recent: 'Active just now',
  working: 'Working',
  waitingForYou: 'Waiting for you',
}
