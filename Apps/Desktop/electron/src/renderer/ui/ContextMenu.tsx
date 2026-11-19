import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import type { MenuEntry } from '../../shared/bridge.ts'
import { Icon, type IconName } from './Icon.tsx'
import styles from './ContextMenu.module.css'

/**
 * A context menu's entries: the same items and order on every platform. The icon shows
 * in the Fluent flyout; the Mac's system menu shows the labels only. `checked` makes an
 * item a toggle (a checkmark in the icon's place); a submenu's items are picked by their
 * own ids.
 */
export type ContextMenuEntry =
  | { kind: 'item'; id: string; label: string; icon?: IconName; disabled?: boolean; destructive?: boolean; checked?: boolean }
  | { kind: 'submenu'; id: string; label: string; icon?: IconName; disabled?: boolean; entries: ContextMenuEntry[] }
  | { kind: 'separator' }

export interface ContextMenuControls {
  /** For `onContextMenu`: opens the menu at the pointer. */
  onContextMenu(event: React.MouseEvent): void
  /** For a "…" button: opens the menu under the button, its leading edges aligned. */
  openBelow(anchor: HTMLElement): void
  /** Whether the menu is open (the "…" button stays shown while it is). */
  isOpen: boolean
  /** The in-app flyout, when one shows; render it anywhere. */
  menu: ReactNode
}

function nativeEntries(entries: ContextMenuEntry[]): MenuEntry[] {
  return entries.map((entry): MenuEntry => {
    switch (entry.kind) {
      case 'separator': return entry
      case 'submenu': return {
        kind: 'submenu', id: entry.id, label: entry.label, entries: nativeEntries(entry.entries),
        ...(entry.disabled ? { disabled: true } : {}),
      }
      case 'item': return {
        kind: 'item', id: entry.id, label: entry.label,
        ...(entry.disabled ? { disabled: true } : {}),
        ...(entry.destructive ? { destructive: true } : {}),
        ...(entry.checked !== undefined ? { checked: entry.checked } : {}),
      }
    }
  })
}

/**
 * One context menu (the Mac's `.contextMenu` and its "…" `Menu`): on macOS the system's
 * menu, shown by the main process (`src/main/ipc/menu.ts`); on Windows a Fluent flyout
 * drawn here (WinUI's MenuFlyout: a rounded card, an icon and label per item, a line
 * between groups, submenus to the side). The main process decides which; this file
 * never checks the platform.
 *
 * `entries` is read when the menu opens, so it always has the row's current state.
 */
export function useContextMenu(entries: () => ContextMenuEntry[], onSelect: (id: string) => void): ContextMenuControls {
  const [flyout, setFlyout] = useState<{ entries: ContextMenuEntry[]; x: number; y: number; document: Document }>()
  const [isOpen, setOpen] = useState(false)
  const latest = useRef({ entries, onSelect })
  latest.current = { entries, onSelect }

  const open = useCallback((x: number, y: number, ownerDocument: Document) => {
    const shown = latest.current.entries()
    if (shown.length === 0) return
    setOpen(true)
    // The settings window is a portal of this renderer (K): one bridge for both.
    const bridge = window.talaria as Window['talaria'] | undefined
    const popup = bridge?.menu?.popup(nativeEntries(shown), x, y) ?? Promise.resolve({ kind: 'inApp' as const })
    void popup.then((outcome) => {
      if (outcome.kind === 'inApp') {
        setFlyout({ entries: shown, x, y, document: ownerDocument })
        return
      }
      setOpen(false)
      if (outcome.kind === 'chosen') latest.current.onSelect(outcome.id)
    }, () => setOpen(false))
  }, [])

  const close = useCallback((chosen?: string) => {
    setFlyout(undefined)
    setOpen(false)
    if (chosen !== undefined) latest.current.onSelect(chosen)
  }, [])

  return {
    onContextMenu(event) {
      event.preventDefault()
      event.stopPropagation()
      open(event.clientX, event.clientY, event.currentTarget.ownerDocument)
    },
    openBelow(anchor) {
      const rect = anchor.getBoundingClientRect()
      open(rect.left, rect.bottom + menuGap, anchor.ownerDocument)
    },
    isOpen,
    menu: flyout
      ? createPortal(
        <div className={styles.backdrop} onMouseDown={(event) => { if (event.target === event.currentTarget) close() }}
          onContextMenu={(event) => { event.preventDefault(); close() }}>
          <MenuList entries={flyout.entries} x={flyout.x} y={flyout.y} document={flyout.document}
            onChoose={close} onDismiss={() => close()} onBack={() => close()} />
        </div>,
        flyout.document.body)
      : null,
  }
}

/** The flyout's distance from a button it opens under (WinUI's 4 px). */
const menuGap = 4

/** One card of the flyout; a submenu opens another beside its item. */
function MenuList({ entries, x, y, document, onChoose, onDismiss, onBack, flipX, autoFocus = true }: {
  entries: ContextMenuEntry[]; x: number; y: number; document: Document
  /** A submenu opened by hover leaves the focus where it is. */
  autoFocus?: boolean
  onChoose: (id: string) => void
  /** Closes the whole menu. */
  onDismiss: () => void
  /** ← or Escape: back to the parent (the root closes). */
  onBack: () => void
  /** For a submenu: the x to open at when there is no room on the right (its parent's left edge). */
  flipX?: number
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState({ left: x, top: y, shown: false })
  const [submenu, setSubmenu] = useState<{ index: number; x: number; y: number; flipX: number; focus: boolean }>()
  const hoverTimer = useRef<ReturnType<typeof setTimeout>>(undefined)

  // Kept inside the window: moved left (or, for a submenu, to its parent's other side) or up.
  useLayoutEffect(() => {
    const element = ref.current
    const view = document.defaultView
    if (!element || !view) return
    const { width, height } = element.getBoundingClientRect()
    const left = x + width <= view.innerWidth ? x : Math.max(0, (flipX ?? x) - width)
    const top = y + height <= view.innerHeight ? y : Math.max(0, view.innerHeight - height)
    setPosition({ left, top, shown: true })
    if (autoFocus) items(element)[0]?.focus()
  }, [x, y, flipX, document, autoFocus])

  useEffect(() => {
    if (flipX !== undefined) return
    const view = document.defaultView
    view?.addEventListener('blur', onDismiss)
    view?.addEventListener('resize', onDismiss)
    return () => {
      view?.removeEventListener('blur', onDismiss)
      view?.removeEventListener('resize', onDismiss)
    }
  }, [document, onDismiss, flipX])

  useEffect(() => () => clearTimeout(hoverTimer.current), [])

  const openSubmenu = (index: number, button: HTMLElement, focus: boolean) => {
    const rect = button.getBoundingClientRect()
    const padding = ref.current ? parseFloat(getComputedStyle(ref.current).paddingTop) || 0 : 0
    setSubmenu({ index, x: rect.right, y: rect.top - padding, flipX: rect.left, focus })
  }

  const onKeyDown = (event: React.KeyboardEvent) => {
    const element = ref.current
    if (!element) return
    const all = items(element)
    const at = all.indexOf(document.activeElement as HTMLButtonElement)
    const move = (index: number) => all[(index + all.length) % all.length]?.focus()
    const current = all[at]
    switch (event.key) {
      case 'Escape': onBack(); break
      case 'ArrowLeft': if (flipX !== undefined) onBack(); break
      case 'Tab': onDismiss(); break
      case 'ArrowDown': move(at + 1); break
      case 'ArrowUp': move(at < 0 ? -1 : at - 1); break
      case 'Home': move(0); break
      case 'End': move(-1); break
      case 'ArrowRight': {
        const index = Number(current?.dataset.index)
        if (current?.getAttribute('aria-haspopup') === 'menu') openSubmenu(index, current, true)
        break
      }
      default: return
    }
    event.preventDefault()
    event.stopPropagation()
  }

  const open = submenu ? entries[submenu.index] : undefined
  return (
    <>
      <div ref={ref} role="menu" className={styles.menu} data-shown={position.shown || undefined}
        style={{ left: position.left, top: position.top }} onKeyDown={onKeyDown}>
        {entries.map((entry, index) => {
          if (entry.kind === 'separator') return <div key={`separator-${index}`} role="separator" className={styles.separator} />
          const isSubmenu = entry.kind === 'submenu'
          const icon = entry.kind === 'item' && entry.checked !== undefined
            ? (entry.checked ? 'check' : undefined)
            : entry.icon
          return (
            <button key={entry.id} type="button" className={styles.item} disabled={entry.disabled} data-index={index}
              role={entry.kind === 'item' && entry.checked !== undefined ? 'menuitemcheckbox' : 'menuitem'}
              {...(entry.kind === 'item' && entry.checked !== undefined ? { 'aria-checked': entry.checked } : {})}
              {...(isSubmenu ? { 'aria-haspopup': 'menu' as const, 'aria-expanded': submenu?.index === index } : {})}
              data-destructive={entry.kind === 'item' && entry.destructive ? true : undefined}
              data-open={submenu?.index === index || undefined}
              onMouseEnter={(event) => {
                clearTimeout(hoverTimer.current)
                const button = event.currentTarget
                // WinUI opens a submenu on hover after a beat, and closes another one.
                hoverTimer.current = setTimeout(() => {
                  if (isSubmenu) openSubmenu(index, button, false)
                  else setSubmenu(undefined)
                }, hoverDelay)
              }}
              onClick={(event) => {
                if (isSubmenu) openSubmenu(index, event.currentTarget, true)
                else onChoose(entry.id)
              }}>
              <span className={styles.icon}>{icon && <Icon name={icon} />}</span>
              <span className={styles.label}>{entry.label}</span>
              {isSubmenu && <span className={styles.chevron}><Icon name="chevronRight" /></span>}
            </button>
          )
        })}
      </div>
      {open?.kind === 'submenu' && submenu && (
        <MenuList key={submenu.index} entries={open.entries} x={submenu.x} y={submenu.y} flipX={submenu.flipX}
          document={document} onChoose={onChoose} onDismiss={onDismiss} autoFocus={submenu.focus}
          onBack={() => {
            const index = submenu.index
            setSubmenu(undefined)
            ref.current?.querySelector<HTMLButtonElement>(`[data-index="${index}"]`)?.focus()
          }} />
      )}
    </>
  )
}

/** Milliseconds the pointer rests on a submenu's item before it opens. */
const hoverDelay = 200

function items(menu: HTMLElement): HTMLButtonElement[] {
  return [...menu.querySelectorAll<HTMLButtonElement>(':scope > button:not(:disabled)')]
}
