import type { ReactNode } from 'react'
import { Icon, type IconName } from '../../../ui/Icon.tsx'
import styles from './Rows.module.css'

/**
 * The Settings building blocks, after Hermes Desktop's settings primitives
 * (`apps/desktop/src/app/settings/primitives.tsx`, MIT): a page heading, titled
 * sections, and the one settings row — title and description on the left, its control
 * on the right. The same on every platform.
 */
export function PageHeading({ icon, title, aside }: { icon: IconName; title: string; aside?: ReactNode }) {
  return (
    <div className={styles.heading}>
      <span className={styles.headingIcon}><Icon name={icon} /></span>
      <h2 className={styles.headingTitle}>{title}</h2>
      {aside && <div className={styles.headingAside}>{aside}</div>}
    </div>
  )
}

export function Caption({ children }: { children: ReactNode }) {
  return <p className={styles.caption}>{children}</p>
}

/** One setting: its name and what it does, and the control that sets it. */
export function ListRow({ title, description, action, below, htmlFor }: {
  title: ReactNode
  description?: ReactNode
  action?: ReactNode
  below?: ReactNode
  htmlFor?: string
}) {
  return (
    <div className={styles.row}>
      <div className={styles.text}>
        {htmlFor ? <label className={styles.title} htmlFor={htmlFor}>{title}</label> : <div className={styles.title}>{title}</div>}
        {description && <div className={styles.description}>{description}</div>}
        {below}
      </div>
      {action && <div className={styles.action}>{action}</div>}
    </div>
  )
}

/** The one boolean row: every on/off setting is a switch. */
export function ToggleRow({ label, description, checked, disabled, onChange }: {
  label: string
  description?: ReactNode
  checked: boolean
  disabled?: boolean
  onChange: (on: boolean) => void
}) {
  return (
    <ListRow title={label} description={description}
      action={<Switch label={label} checked={checked} disabled={disabled} onChange={onChange} />} />
  )
}

export function Switch({ label, checked, disabled, onChange }: {
  label: string
  checked: boolean
  disabled?: boolean
  onChange: (on: boolean) => void
}) {
  return (
    <input type="checkbox" role="switch" className={styles.switch} aria-label={label} checked={checked}
      disabled={disabled} onChange={(event) => onChange(event.target.checked)} />
  )
}

export function TextField({ id, value, onChange, placeholder, type = 'text', autoComplete, label }: {
  id?: string
  value: string
  onChange: (value: string) => void
  placeholder?: string
  type?: 'text' | 'password'
  autoComplete?: string
  label?: string
}) {
  return (
    <input id={id} className={styles.field} type={type} value={value} placeholder={placeholder} spellCheck={false}
      aria-label={label} autoComplete={autoComplete ?? 'off'} onChange={(event) => onChange(event.target.value)} />
  )
}

export function Select<T extends string>({ id, value, options, onChange, label }: {
  id?: string
  value: T
  options: readonly { value: T; label: string }[]
  onChange: (value: T) => void
  label?: string
}) {
  return (
    <select id={id} className={styles.field} value={value} aria-label={label}
      onChange={(event) => onChange(event.target.value as T)}>
      {options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
    </select>
  )
}

export function Button({ children, onClick, disabled, variant = 'outline', label }: {
  children: ReactNode
  onClick?: () => void
  disabled?: boolean
  variant?: 'outline' | 'primary' | 'destructive' | 'ghost'
  label?: string
}) {
  return (
    <button type="button" className={styles.button} data-variant={variant} disabled={disabled} aria-label={label}
      title={label} onClick={onClick}>{children}</button>
  )
}

/** A small status label: Connected, Connecting…, Disconnected. */
export function Pill({ tone, children }: { tone: 'success' | 'caution' | 'neutral' | 'critical'; children: ReactNode }) {
  return <span className={styles.pill} data-tone={tone}><span className={styles.dot} />{children}</span>
}

export function Spinner() {
  return <span className={styles.spinner} aria-hidden="true" />
}
