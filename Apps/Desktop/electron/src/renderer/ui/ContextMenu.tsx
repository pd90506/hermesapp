import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import type { MenuEntry } from '../../shared/bridge.ts'
import { Icon, type IconName } from './Icon.tsx'
import styles from './ContextMenu.module.css'

/**
 * A context menu's entries: the same items and order on every platform. The icon shows
 * in the Fluent flyout; the Mac's system menu shows the labels only.
 */
export type ContextMenuEntry =
  | { kind: 'item'; id: string; label: string; icon?: IconName; disabled?: boolean; destructive?: boolean }
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

/**
 * One context menu (the Mac's `.contextMenu` and its "…" `Menu`): on macOS the system's
 * menu, shown by the main process (`src/main/ipc/menu.ts`); on Windows a Fluent flyout
 * drawn here (WinUI's MenuFlyout: a rounded card, an icon and label per item, a line
 * between groups). The main process decides which; this file never checks the platform.
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
    const native: MenuEntry[] = shown.map((entry) => entry.kind === 'separator' ? entry : {
      kind: 'item', id: entry.id, label: entry.label,
      ...(entry.disabled ? { disabled: true } : {}), ...(entry.destructive ? { destructive: true } : {}),
    })
    const popup = bridge?.menu?.popup(native, x, y) ?? Promise.resolve({ kind: 'inApp' as const })
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
    menu: flyout ? <Flyout {...flyout} onClose={close} /> : null,
  }
}

/** The flyout's distance from a button it opens under (WinUI's 4 px). */
const menuGap = 4

function Flyout({ entries, x, y, document, onClose }: {
  entries: ContextMenuEntry[]; x: number; y: number; document: Document; onClose: (chosen?: string) => void
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState({ left: x, top: y, shown: false })

  // Kept inside the window: moved left or up by its own size when it would overflow.
  useLayoutEffect(() => {
    const element = ref.current
    const view = document.defaultView
    if (!element || !view) return
    const { width, height } = element.getBoundingClientRect()
    const left = x + width > view.innerWidth ? Math.max(0, x - width) : x
    const top = y + height > view.innerHeight ? Math.max(0, y - height) : y
    setPosition({ left, top, shown: true })
    items(element)[0]?.focus()
  }, [x, y, document])

  useEffect(() => {
    const view = document.defaultView
    const dismiss = () => onClose()
    view?.addEventListener('blur', dismiss)
    view?.addEventListener('resize', dismiss)
    return () => {
      view?.removeEventListener('blur', dismiss)
      view?.removeEventListener('resize', dismiss)
    }
  }, [document, onClose])

  const onKeyDown = (event: React.KeyboardEvent) => {
    const element = ref.current
    if (!element) return
    const all = items(element)
    const at = all.indexOf(document.activeElement as HTMLButtonElement)
    const move = (index: number) => all[(index + all.length) % all.length]?.focus()
    switch (event.key) {
      case 'Escape': onClose(); break
      case 'Tab': event.preventDefault(); onClose(); return
      case 'ArrowDown': move(at + 1); break
      case 'ArrowUp': move(at < 0 ? -1 : at - 1); break
      case 'Home': move(0); break
      case 'End': move(-1); break
      default: return
    }
    event.preventDefault()
  }

  return createPortal(
    <div className={styles.backdrop} onMouseDown={(event) => { if (event.target === event.currentTarget) onClose() }}
      onContextMenu={(event) => { event.preventDefault(); onClose() }}>
      <div ref={ref} role="menu" className={styles.menu} data-shown={position.shown || undefined}
        style={{ left: position.left, top: position.top }} onKeyDown={onKeyDown}>
        {entries.map((entry, index) => entry.kind === 'separator'
          ? <div key={`separator-${index}`} role="separator" className={styles.separator} />
          : (
            <button key={entry.id} type="button" role="menuitem" className={styles.item} disabled={entry.disabled}
              data-destructive={entry.destructive || undefined} onClick={() => onClose(entry.id)}>
              <span className={styles.icon}>{entry.icon && <Icon name={entry.icon} />}</span>
              <span className={styles.label}>{entry.label}</span>
            </button>
          ))}
      </div>
    </div>,
    document.body,
  )
}

function items(menu: HTMLElement): HTMLButtonElement[] {
  return [...menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')]
}
