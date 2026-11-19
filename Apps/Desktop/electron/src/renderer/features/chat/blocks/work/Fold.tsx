import { useRef, type ReactNode } from 'react'
import styles from './Work.module.css'

export type Chevron =
  /** Points right, turning down while open. */
  | 'disclosure'
  /** Points down, and up while open: a turn's "Completed in" line. */
  | 'upDown'
  /** A disclosure chevron shown only while the pointer is over the line: a turn's groups and steps. */
  | 'onHover'
  | 'none'

/**
 * The line every fold in the chat opens with (reasoning, a tool call, a turn's work, a
 * group of its steps, a step): its label, then a chevron. The whole line is the button.
 * Opening or closing keeps the line where it was on screen (the Mac's
 * `ChatScroll.keepingPlace`), so the next click closes it again; the pointer over a line
 * that opens is a pointing hand, as over a link (the user, 2026-10-18).
 */
export function FoldButton({ expanded, onToggle, chevron = 'disclosure', disabled = false, label, children, className }: {
  expanded: boolean
  onToggle: (open: boolean) => void
  chevron?: Chevron
  disabled?: boolean
  /** The accessible name, when the line's text is not enough. */
  label?: string
  children: ReactNode
  className?: string
}) {
  const button = useRef<HTMLButtonElement>(null)
  return (
    <button
      ref={button}
      type="button"
      className={[styles.fold, className].filter(Boolean).join(' ')}
      data-chevron={chevron}
      aria-expanded={disabled ? undefined : expanded}
      aria-label={label}
      disabled={disabled}
      onClick={() => {
        if (button.current) keepPlace(button.current)
        onToggle(!expanded)
      }}
    >
      {children}
      {chevron === 'upDown' && <ChevronMark direction={expanded ? 'up' : 'down'} />}
      {(chevron === 'disclosure' || chevron === 'onHover') && <ChevronMark direction={expanded ? 'down' : 'right'} />}
    </button>
  )
}

function ChevronMark({ direction }: { direction: 'right' | 'down' | 'up' }) {
  const path = direction === 'right' ? 'M6 4l4 4-4 4' : direction === 'down' ? 'M4 6l4 4 4-4' : 'M4 10l4-4 4 4'
  return (
    <svg className={styles.chevron} viewBox="0 0 16 16" aria-hidden="true">
      <path d={path} />
    </svg>
  )
}

/**
 * Holds the line at its place in the chat's scroller while the fold opens or closes and
 * the rows around it are measured again (the list would otherwise follow its end, or
 * keep a row above the screen still, and move the line away from the pointer).
 */
function keepPlace(line: HTMLElement): void {
  const scroller = line.closest<HTMLElement>('[data-chat-scroller]')
  if (!scroller) return
  const view = scroller.ownerDocument.defaultView
  if (!view) return
  const offset = () => line.getBoundingClientRect().top - scroller.getBoundingClientRect().top
  const before = offset()
  let frames = 0
  // The user's own scroll ends the hold.
  let released = false
  const release = () => { released = true }
  scroller.addEventListener('wheel', release, { once: true, passive: true })
  scroller.addEventListener('pointerdown', release, { once: true, passive: true })
  const hold = () => {
    if (released || !line.isConnected) return
    const drift = offset() - before
    if (Math.abs(drift) > 0.5) scroller.scrollTop += drift
    frames += 1
    if (frames < 12) view.requestAnimationFrame(hold)
    else {
      scroller.removeEventListener('wheel', release)
      scroller.removeEventListener('pointerdown', release)
    }
  }
  view.requestAnimationFrame(hold)
}
