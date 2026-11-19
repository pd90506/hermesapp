import { useEffect, useRef, type ReactNode } from 'react'
import styles from './Pills.module.css'

/**
 * A pill in the row over the composer (the Mac's `TodoPillLabel` and its siblings): an
 * icon and a count, 32 high, in the composer's glass. Pressed while its card is open.
 */
export function PillButton({ icon, title, label, hint, open, onToggle, testID }: {
  icon: ReactNode
  title: string
  label: string
  hint: string
  open: boolean
  onToggle: () => void
  testID: string
}) {
  return (
    <button type="button" className={styles.pill} aria-label={label} aria-expanded={open} aria-description={hint}
      data-testid={testID} data-open={open || undefined} onClick={onToggle}>
      <span className={styles.pillIcon} aria-hidden="true">{icon}</span>
      <span className={styles.count}>{title}</span>
    </button>
  )
}

/**
 * A pill's card, as wide as the composer just above the row (the Mac's `TodoPanel`,
 * `BackgroundProcessesPanel`, `SubagentsPanel`): a title and a close button over a line,
 * then its rows, scrolling past a height. Esc or a click outside closes it.
 */
export function PillCard({ title, onClose, children, testID }: {
  title: string
  onClose: () => void
  children: ReactNode
  testID: string
}) {
  const card = useRef<HTMLDivElement>(null)
  const close = useRef(onClose)
  close.current = onClose
  useEffect(() => {
    const element = card.current
    const document = element?.ownerDocument
    if (!element || !document) return
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') close.current() }
    // The pills toggle their own card: a press on one is not "outside".
    const onDown = (event: PointerEvent) => {
      const target = event.target as Node | null
      if (target && !element.contains(target) && !(target instanceof Element && target.closest(`.${styles.pill}`))) close.current()
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('pointerdown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('pointerdown', onDown)
    }
  }, [])
  return (
    <div ref={card} className={styles.card} role="dialog" aria-label={title} data-testid={testID}>
      <div className={styles.header}>
        <span className={styles.heading}>{title}</span>
        <button type="button" className={styles.close} aria-label="Close" title="Close" onClick={onClose}>
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" /></svg>
        </button>
      </div>
      <div className={styles.body}>{children}</div>
    </div>
  )
}

/** A small spinner, as the Mac's mini `ProgressView`. */
export function Spinner({ label }: { label?: string }) {
  return <span className={styles.spinner} role={label ? 'progressbar' : undefined} aria-label={label} aria-hidden={label ? undefined : true} />
}

/** A chevron that turns down while its row is open. */
export function Chevron({ open }: { open: boolean }) {
  return (
    <svg className={styles.chevron} data-open={open || undefined} viewBox="0 0 16 16" aria-hidden="true">
      <path d="M6 3.5 10.5 8 6 12.5" />
    </svg>
  )
}
