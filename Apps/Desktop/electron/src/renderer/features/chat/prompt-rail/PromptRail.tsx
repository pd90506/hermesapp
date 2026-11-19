import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { PromptMarks, PromptPicks, type PromptMark, type PromptPick } from '@talaria/hermes-core'
import { registerChatEdge, type ChatEdgeProps } from '../edge.ts'
import styles from './PromptRail.module.css'

/** The room each tick gets at most: a long chat packs its ticks closer. */
const maxSpacing = 14
/** About how tall a panel row is, to place the panel before it is laid out. */
const panelRowEstimate = 26
const panelMaxHeight = 420
/** A short wait before closing, so moving between the rail and the panel does not close it. */
const closeDelay = 150

/** The height of each tick's row: `maxSpacing`, or less so `count` fit in `height`. */
export function tickSpacing(count: number, height: number): number {
  if (count <= 0 || height <= 0) return maxSpacing
  return Math.min(maxSpacing, height / count)
}

/** Where the panel's top goes: level with the first tick, kept inside the rail. */
export function panelTop(count: number, height: number): number {
  const ticksTop = (height - tickSpacing(count, height) * count) / 2
  const panel = Math.min(panelMaxHeight, height, count * panelRowEstimate + 16)
  return Math.max(0, Math.min(ticksTop, height - panel))
}

/**
 * The prompt rail (the Mac's `PromptRail`): a tick per prompt the user sent, oldest at
 * the top, down the chat's trailing edge, like the timeline beside Time Machine's
 * windows; the prompt the chat is at is the long dark one. Hovering the rail opens a
 * panel over it, as Notion's outline does, listing every prompt on one line each; it
 * opens level with the first tick, scrolls when there are more than fit, and opens
 * scrolled to the prompt the chat is at. Clicking a tick or a prompt scrolls the chat to
 * that prompt and its reply, and marks it until the chat is scrolled away (`PromptPick`).
 */
export function PromptRail({ view, blocks, visible, atEnd, bottomInset, scrollToBlock, onUserScroll }: ChatEdgeProps) {
  const marks = useMemo(() => PromptMarks.marks(view.items), [view.items])
  const [pick, setPick] = useState<PromptPick>()
  // The user scrolling ends a pick; so does a new prompt (a send brings the chat to its end).
  useEffect(() => onUserScroll(() => setPick(undefined)), [onUserScroll])
  const lastPrompt = marks.at(-1)?.id
  useEffect(() => { setPick(undefined) }, [lastPrompt])
  // The pick holds until the prompt's block, once on screen, leaves it.
  useEffect(() => {
    setPick((old) => old && PromptPicks.holding(old, visible, blocks))
  }, [visible, blocks])

  const current = PromptMarks.current(blocks, marks, visible, atEnd, pick?.promptID)
  const select = (mark: PromptMark) => {
    setPick(PromptPicks.holding(PromptPicks.pick(mark.id), visible, blocks))
    const block = PromptMarks.blockID(blocks, mark.id)
    if (block !== undefined) scrollToBlock(block)
  }
  if (marks.length === 0) return null
  return (
    <div className={styles.frame} style={{ bottom: bottomInset }}>
      <Rail marks={marks} current={current} select={select} />
    </div>
  )
}

function Rail({ marks, current, select }: { marks: PromptMark[]; current: string | undefined; select: (mark: PromptMark) => void }) {
  const rail = useRef<HTMLDivElement>(null)
  const [height, setHeight] = useState(0)
  useLayoutEffect(() => {
    const element = rail.current
    const window = element?.ownerDocument.defaultView
    if (!element || !window) return
    const observer = new window.ResizeObserver(() => setHeight(element.clientHeight))
    observer.observe(element)
    setHeight(element.clientHeight)
    return () => observer.disconnect()
  }, [])

  const [overRail, setOverRail] = useState(false)
  const [overPanel, setOverPanel] = useState(false)
  const [isOpen, setOpen] = useState(false)
  const hovering = overRail || overPanel
  useEffect(() => {
    if (hovering) { setOpen(true); return }
    const timer = setTimeout(() => setOpen(false), closeDelay)
    return () => clearTimeout(timer)
  }, [hovering])

  const spacing = tickSpacing(marks.length, height)
  return (
    <div ref={rail} className={styles.rail} data-open={isOpen || undefined}>
      <div className={styles.ticks} role="navigation" aria-label="Prompts"
        onMouseEnter={() => setOverRail(true)} onMouseLeave={() => setOverRail(false)}>
        {marks.map((mark) => (
          <button key={mark.id} type="button" className={styles.tick} style={{ height: spacing }}
            aria-label={mark.label} aria-current={mark.id === current ? 'location' : undefined}
            data-current={mark.id === current || undefined} onClick={() => select(mark)} onFocus={() => setOverRail(true)}
            onBlur={() => setOverRail(false)}>
            <span className={styles.bar} />
          </button>
        ))}
      </div>
      {isOpen && (
        <Panel marks={marks} current={current} top={panelTop(marks.length, height)} maxHeight={Math.min(panelMaxHeight, height)}
          select={select} onHover={setOverPanel} />
      )}
    </div>
  )
}

function Panel({ marks, current, top, maxHeight, select, onHover }: {
  marks: PromptMark[]; current: string | undefined; top: number; maxHeight: number
  select: (mark: PromptMark) => void; onHover: (over: boolean) => void
}) {
  const list = useRef<HTMLDivElement>(null)
  // Opens scrolled to the prompt the chat is at.
  useLayoutEffect(() => {
    const element = list.current
    const row = element?.querySelector<HTMLElement>('[data-current]')
    if (element && row) element.scrollTop = row.offsetTop - (element.clientHeight - row.offsetHeight) / 2
  }, [])
  useEffect(() => () => onHover(false), [onHover])
  return (
    <div ref={list} className={styles.panel} style={{ top, maxHeight }} role="list"
      onMouseEnter={() => onHover(true)} onMouseLeave={() => onHover(false)}>
      {marks.map((mark) => (
        <button key={mark.id} type="button" role="listitem" className={styles.row}
          aria-current={mark.id === current ? 'location' : undefined} data-current={mark.id === current || undefined}
          onClick={() => select(mark)}>
          {mark.label}
        </button>
      ))}
    </div>
  )
}

registerChatEdge({ id: 'prompt-rail', Edge: PromptRail })
