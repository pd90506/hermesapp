import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { useVirtualizer } from '@tanstack/react-virtual'
import { MessagesBelow, blockKind, type ChatSession, type ChatView, type TranscriptBlock } from '@talaria/hermes-core'
import { blockRenderer } from './blocks/registry.ts'
import './blocks/registered-blocks.ts'
import { chatEdges } from './edge.ts'
import './registered-edges.ts'
import { HistoryHeader } from './HistoryHeader.tsx'
import { keepScroll, keptScroll } from './kept-scroll.ts'
import { TranscriptFooter } from './TranscriptFooter.tsx'
import styles from './TranscriptList.module.css'

/** How far up from the end the scroll-to-bottom button shows: Desktop's near-bottom band. */
const awayFromEndDistance = 70
/** Within this of the end the list follows a reply as it grows. */
const followDistance = 24

type Row = { key: string; kind: 'header' } | { key: string; kind: 'block'; block: TranscriptBlock } | { key: string; kind: 'footer' }

/** A block the list draws: a reply with no text yet waits for its first words (or C's fold). */
function isListed(block: TranscriptBlock): boolean {
  return !(block.kind === 'item' && block.item.role === 'assistant' && block.item.text.trim() === '')
}

/**
 * The transcript, oldest first, only the rows near the screen built (the Mac's lazy
 * `TranscriptStack`, Desktop's virtual thread). It opens at the newest message and stays
 * there as a reply streams in; scrolled up, it stays put while rows grow or an older
 * page lands above. The header reads the next older page when it comes on screen.
 */
export function TranscriptList({ chat, view, bottomInset, overlay }: {
  chat: ChatSession
  view: ChatView
  /** The composer row's height: it floats over the list's end, the messages under it. */
  bottomInset: number
  /** Drawn over the list's bottom edge: the row of pills (`ChatPillRow`). */
  overlay: (state: { awayFromEnd: boolean; messagesBelow: number; scrollToEnd: () => void }) => ReactNode
}) {
  const scroller = useRef<HTMLDivElement>(null)
  const kept = useRef(keptScroll(chat)).current
  const blocks = view.blocks.filter(isListed)
  const rows: Row[] = [
    { key: 'header', kind: 'header' },
    ...blocks.map((block): Row => ({ key: block.id, kind: 'block', block })),
    { key: 'footer', kind: 'footer' },
  ]
  const newestID = [...blocks].reverse().find((block) =>
    block.kind === 'work' || block.item.role === 'user' || block.item.role === 'assistant')?.id
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scroller.current,
    getItemKey: (index) => rows[index]!.key,
    estimateSize: (index) => estimate(rows[index]!),
    overscan: 6,
    paddingEnd: bottomInset,
    scrollPaddingEnd: bottomInset,
    ...(kept ? { initialMeasurementsCache: kept.measurements, initialOffset: kept.offset } : {}),
  })
  // A row above the screen that changes height moves the rows under it by as much, so
  // the scroll moves with it, whichever way the user scrolls (the virtualizer skips this
  // while scrolling up, and an older page is read exactly then).
  virtualizer.shouldAdjustScrollPositionOnItemSizeChange = (item, _delta, instance) =>
    item.start < (instance.scrollOffset ?? 0)
  const [awayFromEnd, setAwayFromEnd] = useState(false)
  const [visible, setVisible] = useState<ReadonlySet<string>>(new Set())

  // Whether the list follows its end: true at the end (and when it opens there), false
  // once the user scrolls up. The footer row is always last, so the virtualizer's own
  // follow-on-append (which looks for a new last key) never fires; the list follows here.
  const following = useRef(kept ? kept.atEnd : true)
  // Where it is, kept up to date while it is on screen (the ref is gone by unmount).
  const position = useRef({ offset: kept?.offset ?? 0, atEnd: following.current })

  // Opens at the newest message, or where it was left; then, while following, every
  // change (a new message, a reply growing, a row measured) keeps the end in view.
  // A new prompt at the end (sent from here or elsewhere) brings the list back to the end.
  const newestPrompt = [...blocks].reverse().find((block) => block.kind === 'item' && block.item.role === 'user')?.id
  const seenPrompt = useRef(newestPrompt)
  // The first message on screen and how far below the top it sits, so an older page
  // landing above leaves it where it was (the header's key never changes, so the
  // virtualizer's own anchor would hold the header instead).
  const anchor = useRef<{ key: string; delta: number }>(undefined)
  const firstBlock = blocks[0]?.id
  const seenFirst = useRef(firstBlock)
  const holding = useRef<{ key: string; delta: number }>(undefined)
  // The user scrolling, for the trailing edge (G's prompt rail ends a pick with it).
  const scrollListeners = useRef(new Set<() => void>()).current
  const onUserScroll = useCallback((listener: () => void) => {
    scrollListeners.add(listener)
    return () => { scrollListeners.delete(listener) }
  }, [scrollListeners])
  const release = useCallback(() => {
    holding.current = undefined
    for (const listener of scrollListeners) listener()
  }, [scrollListeners])
  const restored = useRef(false)
  useLayoutEffect(() => {
    const element = scroller.current
    if (!element) return
    if (firstBlock !== seenFirst.current) {
      seenFirst.current = firstBlock
      if (anchor.current && !following.current && restored.current) holding.current = anchor.current
    }
    // Held until the user scrolls again: the new rows (and the header) are measured over
    // the next frames, and each measurement would otherwise move the message.
    const held = holding.current
    if (held) {
      const item = virtualizer.measurementsCache.find((candidate) => candidate.key === held.key)
      const top = item ? item.start - held.delta : undefined
      if (top !== undefined && Math.abs(element.scrollTop - top) > 0.5) element.scrollTop = top
    }
    if (newestPrompt !== seenPrompt.current) {
      seenPrompt.current = newestPrompt
      if (restored.current) following.current = true
    }
    if (following.current) {
      const end = element.scrollHeight - element.clientHeight
      if (Math.abs(element.scrollTop - end) > 1) element.scrollTop = end
    } else if (!restored.current && kept) {
      element.scrollTop = kept.offset
    }
    restored.current = true
  })

  const measureView = useCallback(() => {
    const element = scroller.current
    if (!element) return
    const top = element.scrollTop
    const bottom = top + element.clientHeight
    const distance = element.scrollHeight - bottom
    setAwayFromEnd(distance > awayFromEndDistance)
    const shownBottom = bottom - bottomInset
    const shown = new Set<string>()
    let first: { key: string; delta: number } | undefined
    for (const item of virtualizer.getVirtualItems()) {
      if (item.end > top && item.start < shownBottom) {
        shown.add(String(item.key))
        if (!first && item.index > 0) first = { key: String(item.key), delta: item.start - top }
      }
    }
    if (!holding.current) anchor.current = first
    setVisible((old) => sameSet(old, shown) ? old : shown)
    position.current = { offset: top, atEnd: following.current }
  }, [virtualizer, bottomInset])

  const onScroll = useCallback(() => {
    const element = scroller.current
    if (element && restored.current) {
      following.current = element.scrollHeight - element.scrollTop - element.clientHeight <= followDistance
    }
    measureView()
  }, [measureView])

  useEffect(() => { measureView() })

  // On leaving the screen: where it was, for when it comes back.
  useEffect(() => () => {
    keepScroll(chat, { ...position.current, measurements: virtualizer.takeSnapshot() })
  }, [chat, virtualizer])

  // The header on screen reads the next older page, once the layout has settled.
  const headerShown = visible.has('header')
  useEffect(() => {
    if (!headerShown || !view.paging.hasOlder || view.historyLoad.phase !== 'idle') return
    const timer = setTimeout(() => { void chat.loadOlderMessages() }, 300)
    return () => clearTimeout(timer)
  }, [headerShown, view.paging.hasOlder, view.historyLoad.phase, view.items.length, chat])

  const scrollToEnd = useCallback(() => {
    const reduce = scroller.current?.ownerDocument.defaultView?.matchMedia('(prefers-reduced-motion: reduce)').matches
    const element = scroller.current
    if (!element) return
    element.scrollTo({ top: element.scrollHeight - element.clientHeight, behavior: reduce ? 'auto' : 'smooth' })
  }, [])

  const messagesBelow = MessagesBelow.count(blocks, visible)

  // A block to the top of the list (G's prompt rail): it stops following the end.
  const scrollToBlock = useCallback((id: string) => {
    const index = rows.findIndex((row) => row.key === id)
    if (index < 0) return
    holding.current = undefined
    following.current = false
    virtualizer.scrollToIndex(index, { align: 'start' })
  }, [rows, virtualizer])

  return (
    <div className={styles.frame}>
      <div ref={scroller} className={styles.scroller} onScroll={onScroll} data-chat-scroller=""
        onWheel={release} onTouchStart={release} onKeyDown={release} onPointerDown={release}
        style={bottomInset > 0 ? { maskImage: fade(bottomInset) } : undefined}>
        <div className={styles.content} style={{ height: virtualizer.getTotalSize() }}>
          {virtualizer.getVirtualItems().map((item) => {
            const row = rows[item.index]!
            return (
              <div key={item.key} ref={virtualizer.measureElement} data-index={item.index} data-kind={row.kind} className={styles.row}
                style={{ transform: `translateY(${item.start}px)` }}>
                <div className={styles.column}>
                  {row.kind === 'header' && <HistoryHeader view={view} retry={() => { void chat.retryHistory() }} />}
                  {row.kind === 'block' && <Block block={row.block} chat={chat} isNewest={row.block.id === newestID} />}
                  {row.kind === 'footer' && <TranscriptFooter chat={chat} view={view} />}
                </div>
              </div>
            )
          })}
        </div>
      </div>
      {chatEdges().map(({ id, Edge }) => (
        <Edge key={id} chat={chat} view={view} blocks={blocks} visible={visible} atEnd={!awayFromEnd}
          bottomInset={bottomInset} scrollToBlock={scrollToBlock} onUserScroll={onUserScroll} />
      ))}
      <div className={styles.overlay} style={{ bottom: bottomInset }}>{overlay({ awayFromEnd, messagesBelow, scrollToEnd })}</div>
    </div>
  )
}

function Block({ block, chat, isNewest }: { block: TranscriptBlock; chat: ChatSession; isNewest: boolean }) {
  const Renderer = blockRenderer(blockKind(block))
  return Renderer ? <Renderer block={block} chat={chat} isNewest={isNewest} /> : null
}

/** A row's height before it is measured: about a line of 90 characters at the content size. */
function estimate(row: Row): number {
  if (row.kind !== 'block') return row.kind === 'header' ? 28 : 12
  if (row.block.kind === 'work') return 40
  const item = row.block.item
  if (item.role === 'tool' || item.role === 'system') return 32
  const lines = item.text.split('\n').reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / 90)), 0)
  return 12 + 20 + lines * 21
}

/** Opaque down to the composer row's top, clear from its middle (55 %) down. */
function fade(inset: number): string {
  return `linear-gradient(to bottom, black calc(100% - ${inset}px), transparent calc(100% - ${Math.round(inset * 0.45)}px))`
}

function sameSet(a: ReadonlySet<string>, b: ReadonlySet<string>): boolean {
  if (a.size !== b.size) return false
  for (const value of a) if (!b.has(value)) return false
  return true
}
