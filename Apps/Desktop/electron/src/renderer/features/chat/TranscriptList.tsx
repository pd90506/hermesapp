import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { useVirtualizer } from '@tanstack/react-virtual'
import { MessagesBelow, blockKind, type ChatSession, type ChatView, type TranscriptBlock } from '@talaria/hermes-core'
import { blockRenderer } from './blocks/registry.ts'
import './blocks/registered-blocks.ts'
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
    anchorTo: 'end',
    followOnAppend: true,
    scrollEndThreshold: followDistance,
    paddingEnd: bottomInset,
    scrollPaddingEnd: bottomInset,
    ...(kept ? { initialMeasurementsCache: kept.measurements } : {}),
    ...(kept && !kept.atEnd ? { initialOffset: kept.offset } : {}),
  })
  const [awayFromEnd, setAwayFromEnd] = useState(false)
  const [visible, setVisible] = useState<ReadonlySet<string>>(new Set())

  // Opens at the newest message (or where it was left).
  const opened = useRef(false)
  useLayoutEffect(() => {
    if (opened.current || rows.length <= 2) return
    opened.current = true
    if (!kept || kept.atEnd) virtualizer.scrollToIndex(rows.length - 1, { align: 'end' })
  })

  const measureView = useCallback(() => {
    const element = scroller.current
    if (!element) return
    const top = element.scrollTop
    const bottom = top + element.clientHeight
    setAwayFromEnd(element.scrollHeight - bottom > awayFromEndDistance)
    const shownBottom = bottom - bottomInset
    const shown = new Set<string>()
    for (const item of virtualizer.getVirtualItems()) {
      if (item.end > top && item.start < shownBottom) shown.add(String(item.key))
    }
    setVisible((old) => sameSet(old, shown) ? old : shown)
  }, [virtualizer, bottomInset])

  useEffect(() => { measureView() })

  // On leaving the screen: where it was, for when it comes back.
  useEffect(() => () => {
    const element = scroller.current
    keepScroll(chat, {
      offset: element?.scrollTop ?? 0,
      atEnd: element ? element.scrollHeight - element.scrollTop - element.clientHeight <= followDistance : true,
      measurements: virtualizer.takeSnapshot(),
    })
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
    virtualizer.scrollToIndex(rows.length - 1, { align: 'end', behavior: reduce ? 'auto' : 'smooth' })
  }, [virtualizer, rows.length])

  const messagesBelow = MessagesBelow.count(blocks, visible)

  return (
    <div className={styles.frame}>
      <div ref={scroller} className={styles.scroller} onScroll={measureView} data-chat-scroller=""
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
