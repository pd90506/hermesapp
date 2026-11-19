import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import styles from './CronMenu.module.css'

export type CronMenuItem =
  | { kind: 'action'; label: string; onSelect: () => void; disabled?: boolean; destructive?: boolean; id?: string }
  | { kind: 'toggle'; label: string; checked: boolean; onToggle: (on: boolean) => void; disabled?: boolean }
  | { kind: 'submenu'; label: string; items: CronMenuItem[]; disabled?: boolean }
  | { kind: 'divider' }

/**
 * A job's menu, from its "…" button or a right-click: the Mac's `Menu` items in its
 * order (Run Now, Edit…, Pause or Resume, Deliver To ▸, Delete…). A small flyout of
 * this tab's own until the sidebar's shared context menu lands (work package H); then
 * this file goes and the items move to it unchanged.
 */
export function CronMenu({ items, at, onClose, label }: {
  items: CronMenuItem[]
  /** Where the menu opens, in window coordinates. */
  at: { x: number; y: number }
  onClose: () => void
  label: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState(at)
  useLayoutEffect(() => {
    // Kept inside the window, as a native menu flips at the screen's edge.
    const element = ref.current
    if (!element) return
    const view = element.ownerDocument.defaultView
    if (!view) return
    const { width, height } = element.getBoundingClientRect()
    setPosition({
      x: Math.max(0, Math.min(at.x, view.innerWidth - width)),
      y: at.y + height > view.innerHeight ? Math.max(0, at.y - height) : at.y,
    })
  }, [at])
  useEffect(() => {
    const element = ref.current
    const doc = element?.ownerDocument
    if (!doc) return
    const down = (event: MouseEvent) => {
      if (!element.contains(event.target as Node)) onClose()
    }
    const key = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    doc.addEventListener('mousedown', down, true)
    doc.addEventListener('keydown', key, true)
    element.querySelector<HTMLElement>('[role^="menuitem"]:not([aria-disabled="true"])')?.focus()
    return () => {
      doc.removeEventListener('mousedown', down, true)
      doc.removeEventListener('keydown', key, true)
    }
  }, [onClose])
  return (
    <div ref={ref} className={styles.menu} role="menu" aria-label={label}
      style={{ left: position.x, top: position.y }}>
      <MenuItems items={items} onClose={onClose} />
    </div>
  )
}

function MenuItems({ items, onClose }: { items: CronMenuItem[]; onClose: () => void }) {
  const [open, setOpen] = useState<number>()
  return items.map((item, index) => {
    switch (item.kind) {
      case 'divider':
        return <div key={index} className={styles.divider} role="separator" />
      case 'action':
        return (
          <button key={index} type="button" role="menuitem" className={styles.item}
            data-destructive={item.destructive || undefined} data-id={item.id}
            aria-disabled={item.disabled || undefined} disabled={item.disabled}
            onMouseEnter={() => setOpen(undefined)}
            onClick={() => { onClose(); item.onSelect() }}>
            <span className={styles.check} />
            <span className={styles.label}>{item.label}</span>
          </button>
        )
      case 'toggle':
        return (
          <button key={index} type="button" role="menuitemcheckbox" className={styles.item}
            aria-checked={item.checked} aria-disabled={item.disabled || undefined} disabled={item.disabled}
            onClick={() => { onClose(); item.onToggle(!item.checked) }}>
            <span className={styles.check}>{item.checked ? '✓' : ''}</span>
            <span className={styles.label}>{item.label}</span>
          </button>
        )
      case 'submenu':
        return (
          <div key={index} className={styles.submenu} onMouseEnter={() => setOpen(index)}
            onMouseLeave={() => setOpen(undefined)}>
            <button type="button" role="menuitem" className={styles.item} aria-haspopup="menu"
              aria-expanded={open === index} aria-disabled={item.disabled || undefined} disabled={item.disabled}
              onClick={() => setOpen(open === index ? undefined : index)}>
              <span className={styles.check} />
              <span className={styles.label}>{item.label}</span>
              <span className={styles.arrow}>›</span>
            </button>
            {open === index && !item.disabled && (
              <div className={`${styles.menu} ${styles.nested}`} role="menu" aria-label={item.label}>
                <MenuItems items={item.items} onClose={onClose} />
              </div>
            )}
          </div>
        )
    }
  })
}
