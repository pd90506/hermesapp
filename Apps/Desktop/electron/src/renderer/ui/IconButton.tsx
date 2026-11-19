import { Icon, type IconName } from './Icon.tsx'
import styles from './IconButton.module.css'

/** A borderless button with an icon: WinUI's subtle button, the Mac toolbar's plain one. */
export function IconButton({ icon, label, onClick, disabled = false }: {
  icon: IconName
  label: string
  onClick?: () => void
  disabled?: boolean
}) {
  return (
    <button type="button" className={styles.button} title={label} aria-label={label} disabled={disabled} onClick={onClick}>
      <Icon name={icon} />
    </button>
  )
}
