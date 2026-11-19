import { avatarColor, type Bot, type BotActivity } from '@talaria/hermes-core'
import styles from './BotAvatar.module.css'
import { fallbackColor, initials } from './avatar.ts'

/**
 * A profile's avatar, as the Mac's `BotAvatar`: its initials in white on its colour
 * (one of eight, by its name), a circle that turns into a rounded square when selected
 * or hovered, and the badge of what it is doing; its image when it has one, and the
 * colour picked in Hermes Desktop before the fallback.
 */
export function BotAvatar({ bot, activity, squared, image }: {
  bot: Bot; activity: BotActivity; squared: boolean
  /** The profile's avatar image (a data URL), when it has one. */
  image?: string
}) {
  const name = bot.displayName
  return (
    <span className={styles.avatar} data-squared={squared || undefined}>
      <span className={styles.face} style={{ '--avatar-color': avatarColor(bot) ?? fallbackColor(name) } as React.CSSProperties}>
        {image ? <img className={styles.image} src={image} alt="" draggable={false} /> : initials(name)}
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
