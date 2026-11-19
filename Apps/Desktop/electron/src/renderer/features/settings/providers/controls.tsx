import { useEffect, useId, useRef, useState, type ReactNode } from 'react'
import styles from './controls.module.css'

/**
 * The settings panes' form pieces, after the Mac's grouped `Form` and WinUI's settings
 * cards: a section of rows with a header and footer, a row with its label on the left and
 * its control on the right, a segmented picker, a switch, a modal dialog. Shared by the
 * Providers and Capabilities panes.
 */
export function Section({ header, footer, children }: { header?: ReactNode; footer?: ReactNode; children?: ReactNode }) {
  return (
    <section className={styles.section}>
      {header && <h3 className={styles.sectionHeader}>{header}</h3>}
      {children && <div className={styles.sectionBody}>{children}</div>}
      {footer && <div className={styles.sectionFooter}>{footer}</div>}
    </section>
  )
}

export function Row({ label, detail, children, testID }: { label: ReactNode; detail?: ReactNode; children?: ReactNode; testID?: string }) {
  return (
    <div className={styles.row} data-testid={testID}>
      <div className={styles.rowLabel}>
        <div className={styles.rowTitle}>{label}</div>
        {detail && <div className={styles.rowDetail}>{detail}</div>}
      </div>
      {children && <div className={styles.rowControl}>{children}</div>}
    </div>
  )
}

export function Segmented<T extends string>({ label, value, options, onChange }: {
  label: string
  value: T
  options: ReadonlyArray<{ value: T; title: string }>
  onChange: (value: T) => void
}) {
  return (
    <div className={styles.segmented} role="tablist" aria-label={label}>
      {options.map((option) => (
        <button key={option.value} type="button" role="tab" aria-selected={option.value === value}
          className={option.value === value ? styles.segmentSelected : styles.segment}
          onClick={() => onChange(option.value)}>
          {option.title}
        </button>
      ))}
    </div>
  )
}

/** A native checkbox drawn as the platform's switch (NSSwitch, WinUI ToggleSwitch). */
export function Switch({ checked, disabled, label, onChange }: {
  checked: boolean
  disabled?: boolean
  label: string
  onChange: (checked: boolean) => void
}) {
  return (
    <input type="checkbox" role="switch" className={styles.switch} checked={checked} disabled={disabled}
      aria-label={label} onChange={(event) => onChange(event.target.checked)} />
  )
}

export function Spinner({ label = 'Saving' }: { label?: string }) {
  return <span className={styles.spinner} role="progressbar" aria-label={label} />
}

export function Button({ children, onClick, kind = 'normal', disabled, testID }: {
  children: ReactNode
  onClick?: () => void
  kind?: 'normal' | 'primary' | 'borderless' | 'destructive'
  disabled?: boolean
  testID?: string
}) {
  const className = { normal: styles.button, primary: styles.primary, borderless: styles.borderless, destructive: styles.destructive }[kind]
  return <button type="button" className={className} disabled={disabled} onClick={onClick} data-testid={testID}>{children}</button>
}

/**
 * A modal dialog (`<dialog>.showModal()`): Escape and Cancel close it. It opens in the
 * document its element is in, so it works in the settings window too.
 */
export function Dialog({ open, title, onClose, children, actions, wide }: {
  open: boolean
  title: ReactNode
  onClose: () => void
  children?: ReactNode
  actions?: ReactNode
  wide?: boolean
}) {
  const ref = useRef<HTMLDialogElement>(null)
  const titleID = useId()
  useEffect(() => {
    const dialog = ref.current
    if (!dialog) return
    if (open && !dialog.open) {
      if (typeof dialog.showModal === 'function') dialog.showModal()
      else dialog.setAttribute('open', '')
    } else if (!open && dialog.open) {
      if (typeof dialog.close === 'function') dialog.close()
      else dialog.removeAttribute('open')
    }
  }, [open])
  return (
    <dialog ref={ref} className={wide ? styles.dialogWide : styles.dialog} aria-labelledby={titleID}
      onCancel={(event) => { event.preventDefault(); onClose() }}>
      {open && (
        <>
          <h2 id={titleID} className={styles.dialogTitle}>{title}</h2>
          {children && <div className={styles.dialogBody}>{children}</div>}
          {actions && <div className={styles.dialogActions}>{actions}</div>}
        </>
      )}
    </dialog>
  )
}

/** A confirmation (the Mac's `confirmationDialog`): a message and one destructive action. */
export function Confirm({ open, title, message, action, onConfirm, onClose }: {
  open: boolean
  title: string
  message?: string
  action: string
  onConfirm: () => void
  onClose: () => void
}) {
  return (
    <Dialog open={open} title={title} onClose={onClose}
      actions={<>
        <Button onClick={onClose}>Cancel</Button>
        <Button kind="destructive" onClick={() => { onConfirm(); onClose() }}>{action}</Button>
      </>}>
      {message && <p className={styles.message}>{message}</p>}
    </Dialog>
  )
}

/** A field with its label above it, as the Connect page's. */
export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className={styles.field}>
      <span className={styles.fieldLabel}>{label}</span>
      {children}
    </label>
  )
}

export const inputClass = styles.input
export const messageClass = styles.message
export const errorClass = styles.error

/** A "…" button with a small menu of actions (the Mac's borderless `Menu`). */
export function MoreMenu({ items, label = 'More actions' }: {
  items: ReadonlyArray<{ title: string; onSelect: () => void; disabled?: boolean; destructive?: boolean }>
  label?: string
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const doc = ref.current?.ownerDocument
    const close = (event: Event) => {
      if (event instanceof KeyboardEvent && event.key !== 'Escape') return
      if (event.type === 'pointerdown' && ref.current?.contains(event.target as Node)) return
      setOpen(false)
    }
    doc?.addEventListener('pointerdown', close)
    doc?.addEventListener('keydown', close)
    return () => {
      doc?.removeEventListener('pointerdown', close)
      doc?.removeEventListener('keydown', close)
    }
  }, [open])
  return (
    <div className={styles.menuAnchor} ref={ref}>
      <button type="button" className={styles.moreButton} aria-label={label} aria-haspopup="menu" aria-expanded={open}
        onClick={() => setOpen(!open)}>
        <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="3.5" cy="8" r="1.2" /><circle cx="8" cy="8" r="1.2" /><circle cx="12.5" cy="8" r="1.2" /></svg>
      </button>
      {open && (
        <div className={styles.menu} role="menu">
          {items.map((item) => (
            <button key={item.title} type="button" role="menuitem" disabled={item.disabled}
              className={item.destructive ? styles.menuItemDestructive : styles.menuItem}
              onClick={() => { setOpen(false); item.onSelect() }}>
              {item.title}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
