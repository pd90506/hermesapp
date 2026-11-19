import type { ReactNode } from 'react'
import styles from './Form.module.css'

/**
 * The Settings panes' form, as the Mac's `.formStyle(.columns)`: labels right-aligned in
 * a column, controls left-aligned beside them, notes under a control.
 */
export function Form({ children }: { children: ReactNode }) {
  return <div className={styles.form}>{children}</div>
}

/** A labelled row. Without a label, the control sits in the trailing column. */
export function Row({ label, children, htmlFor }: { label?: string; children: ReactNode; htmlFor?: string }) {
  return (
    <div className={styles.row}>
      {label ? <label className={styles.label} htmlFor={htmlFor}>{label}</label> : <span className={styles.label} />}
      <div className={styles.control}>{children}</div>
    </div>
  )
}

/** A footnote under a control (the Mac's `SettingsNote`). */
export function Note({ children }: { children: ReactNode }) {
  return <p className={styles.note}>{children}</p>
}

/** A switch: the Mac's checkbox toggle, WinUI's ToggleSwitch (platform.css picks). */
export function Toggle({ label, checked, disabled, onChange, detail, id }: {
  label: ReactNode
  checked: boolean
  disabled?: boolean
  onChange: (checked: boolean) => void
  detail?: ReactNode
  id?: string
}) {
  return (
    <label className={styles.toggle} data-disabled={disabled || undefined}>
      <input id={id} type="checkbox" className={styles.check} checked={checked} disabled={disabled}
        onChange={(event) => onChange(event.target.checked)} />
      <span className={styles.toggleLabel}>{label}{detail && <span className={styles.secondary}> {detail}</span>}</span>
    </label>
  )
}

export function TextField({ id, value, onChange, placeholder, type = 'text', autoComplete }: {
  id?: string
  value: string
  onChange: (value: string) => void
  placeholder?: string
  type?: 'text' | 'password'
  autoComplete?: string
}) {
  return (
    <input id={id} className={styles.field} type={type} value={value} placeholder={placeholder} spellCheck={false}
      autoComplete={autoComplete ?? 'off'} onChange={(event) => onChange(event.target.value)} />
  )
}

export function Select<T extends string>({ id, value, options, onChange }: {
  id?: string
  value: T
  options: readonly { value: T; label: string }[]
  onChange: (value: T) => void
}) {
  return (
    <select id={id} className={styles.select} value={value} onChange={(event) => onChange(event.target.value as T)}>
      {options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
    </select>
  )
}

export function Button({ children, onClick, disabled, primary, destructive }: {
  children: ReactNode
  onClick?: () => void
  disabled?: boolean
  primary?: boolean
  destructive?: boolean
}) {
  return (
    <button type="button" className={primary ? styles.primary : styles.button} data-destructive={destructive || undefined}
      disabled={disabled} onClick={onClick}>{children}</button>
  )
}

/** A segmented control on a box's top edge (the Mac's Mail-style account tabs). */
export function Segmented<T extends string>({ value, options, onChange, label }: {
  value: T
  options: readonly { value: T; label: string }[]
  onChange: (value: T) => void
  label: string
}) {
  return (
    <div className={styles.segmented} role="tablist" aria-label={label}>
      {options.map((option) => (
        <button key={option.value} type="button" role="tab" aria-selected={option.value === value}
          className={styles.segment} data-selected={option.value === value || undefined}
          onClick={() => onChange(option.value)}>{option.label}</button>
      ))}
    </div>
  )
}

export function Spinner() {
  return <span className={styles.spinner} aria-hidden="true" />
}
