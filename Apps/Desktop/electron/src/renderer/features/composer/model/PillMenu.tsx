import { useEffect, useLayoutEffect, useRef, type KeyboardEvent, type ReactNode } from 'react'
import styles from './PillMenu.module.css'

/** Puts the keyboard back in the composer's text area (Desktop's `releaseTypingFocus`). */
export function focusComposerText(from: Element | null): void {
  let node = from?.parentElement ?? null
  while (node) {
    const text = node.querySelector('textarea')
    if (text) {
      text.focus()
      return
    }
    node = node.parentElement
  }
}

/**
 * A composer pill and the menu it opens (Desktop's `ModelPill` / `ReasoningPill`
 * dropdowns, the same on every platform): the menu opens upward from the pill, its start
 * edge on the pill's, and scrolls past `--composer-menu-max-height`. Arrow keys move
 * between items; Esc, a click outside or a pick closes it, and the keyboard goes back
 * to the composer.
 */
export function PillMenu({ label, title, accessibleLabel, disabled, open, onOpenChange, wide, children, footer }: {
  label: ReactNode
  title: string
  accessibleLabel: string
  disabled?: boolean
  open: boolean
  onOpenChange: (open: boolean) => void
  /** The model menu's width; the effort menu is narrower. */
  wide?: boolean
  children: ReactNode
  /** Under the scrolling list, after a divider (Reload Models). */
  footer?: ReactNode
}) {
  const anchor = useRef<HTMLSpanElement>(null)
  const menu = useRef<HTMLDivElement>(null)

  const close = (returnFocus: boolean) => {
    onOpenChange(false)
    if (returnFocus) focusComposerText(anchor.current)
  }

  useEffect(() => {
    if (!open) return
    const document = anchor.current?.ownerDocument
    if (!document) return
    const onPointer = (event: PointerEvent) => {
      if (!anchor.current?.contains(event.target as Node)) onOpenChange(false)
    }
    document.addEventListener('pointerdown', onPointer, true)
    return () => document.removeEventListener('pointerdown', onPointer, true)
  }, [open, onOpenChange])

  // The checked item, else the first, takes the keyboard; it scrolls into view.
  useLayoutEffect(() => {
    if (!open) return
    keepInWindow(menu.current)
    const items = menuItems(menu.current)
    const start = items.find((item) => item.getAttribute('aria-checked') === 'true') ?? items[0]
    start?.focus()
    start?.scrollIntoView?.({ block: 'nearest' })
  }, [open])

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const items = menuItems(menu.current)
    const index = items.indexOf(event.target as HTMLElement)
    const move = (to: number) => {
      event.preventDefault()
      items[(to + items.length) % items.length]?.focus()
    }
    switch (event.key) {
      case 'Escape': event.preventDefault(); event.stopPropagation(); close(true); break
      case 'ArrowDown': move(index + 1); break
      case 'ArrowUp': move(index < 0 ? items.length - 1 : index - 1); break
      case 'Home': move(0); break
      case 'End': move(items.length - 1); break
      case 'Tab': close(false); break
      default: break
    }
  }

  return (
    <span ref={anchor} className={styles.anchor}>
      <button type="button" className={styles.pill} title={title} aria-label={accessibleLabel} aria-haspopup="menu"
        aria-expanded={open} disabled={disabled} data-open={open || undefined} onClick={() => onOpenChange(!open)}>
        <span className={styles.pillLabel}>{label}</span>
        <svg className={styles.chevron} viewBox="0 0 10 10" aria-hidden="true"><path d="M2.5 3.75 5 6.25l2.5-2.5" /></svg>
      </button>
      {open && (
        <div ref={menu} className={wide ? styles.menuWide : styles.menu} role="menu" aria-label={accessibleLabel}
          onKeyDown={onKeyDown} onClick={(event) => {
            if ((event.target as HTMLElement).closest('[data-closes]')) close(true)
          }}>
          <div className={styles.scroll}>{children}</div>
          {footer && <div className={styles.footer}>{footer}</div>}
        </div>
      )}
    </span>
  )
}

/** Start-aligned with the pill, but moved back in when it would reach past the window's edge. */
export function keepInWindow(element: HTMLElement | null): void {
  const view = element?.ownerDocument.defaultView
  if (!element || !view) return
  element.style.translate = ''
  const margin = 8
  const rect = element.getBoundingClientRect()
  const overflow = rect.right - (view.innerWidth - margin)
  const shift = overflow > 0 ? Math.min(overflow, Math.max(0, rect.left - margin)) : 0
  if (shift > 0) element.style.translate = `${-shift}px 0`
}

function menuItems(menu: HTMLElement | null): HTMLElement[] {
  return menu ? [...menu.querySelectorAll<HTMLElement>('[role^="menuitem"]:not([aria-disabled="true"])')] : []
}

/** A section title in a menu (a provider, "Reasoning Effort"). */
export function MenuSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div role="group" aria-label={title} className={styles.section}>
      <div className={styles.sectionTitle} aria-hidden="true">{title}</div>
      {children}
    </div>
  )
}

/** A pickable row with a check mark when it is the current one; picking it closes the menu. */
export function MenuChoice({ label, checked, onSelect, detail }: { label: string; checked: boolean; onSelect: () => void; detail?: string }) {
  return (
    <button type="button" role="menuitemradio" aria-checked={checked} className={styles.item} data-closes tabIndex={-1}
      title={detail} onClick={onSelect}>
      <svg className={styles.check} viewBox="0 0 14 14" aria-hidden="true">{checked && <path d="M3 7.2 5.8 10 11 4.2" />}</svg>
      <span className={styles.itemLabel}>{label}</span>
    </button>
  )
}

/** A command row (Reload Models); it keeps the menu open while it works. */
export function MenuAction({ label, onSelect, busy, disabled }: { label: string; onSelect: () => void; busy?: boolean; disabled?: boolean }) {
  return (
    <button type="button" role="menuitem" className={styles.action} tabIndex={-1} aria-disabled={disabled || undefined}
      disabled={disabled} onClick={onSelect}>
      <svg className={busy ? styles.spinning : styles.actionIcon} viewBox="0 0 14 14" aria-hidden="true">
        <path d="M11.5 7A4.5 4.5 0 1 1 10 3.6M11.5 1.8v2.6H8.9" />
      </svg>
      <span className={styles.itemLabel}>{label}</span>
    </button>
  )
}

/** A line that isn't a choice ("Loading models…"). */
export function MenuNote({ children }: { children: ReactNode }) {
  return <div className={styles.note}>{children}</div>
}
