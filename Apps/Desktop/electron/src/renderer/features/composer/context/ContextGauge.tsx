import { useEffect, useRef, useState } from 'react'
import {
  contextGauge, contextSummary, formatTokens, gaugeFraction, unitemizedTokens,
  type ContextBreakdown, type ContextGauge as Gauge, type SessionUsage,
} from '@talaria/hermes-core'
import { useSnapshot } from '../../../app/hooks.ts'
import { focusComposerText } from '../model/PillMenu.tsx'
import type { ComposerSlotProps } from '../slots.ts'
import styles from './ContextGauge.module.css'

const usd = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 4 })

/**
 * How full the chat's context is (the Mac's `ContextGaugeButton`, Desktop's status-bar
 * usage): a ring filling with the context used and its percentage, which opens the
 * details: what fills the context and the session's tokens, calls, cache hits and speed.
 * Hidden until the gateway reports any. Read again when the chat shows, when a turn ends
 * and after a compression; a running turn streams its own.
 */
export function ContextGaugeButton({ chat, composer }: ComposerSlotProps) {
  const usage = useSnapshot(chat.usage)
  const view = useSnapshot(chat)
  const { isCompressing } = useSnapshot(composer)
  const [open, setOpen] = useState(false)
  const anchor = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!view.isRunning && !isCompressing) void chat.usage.refresh(chat)
  }, [chat, view.sessionID, view.isRunning, isCompressing])

  useEffect(() => setOpen(false), [chat])

  useEffect(() => {
    if (!open) return
    const document = anchor.current?.ownerDocument
    if (!document) return
    const onPointer = (event: PointerEvent) => { if (!anchor.current?.contains(event.target as Node)) setOpen(false) }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      setOpen(false)
      focusComposerText(anchor.current)
    }
    document.addEventListener('pointerdown', onPointer, true)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('pointerdown', onPointer, true)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  const gauge = contextGauge(usage, view.isRunning)
  if (!gauge && !usage.usage) return null
  const summary = gauge ? contextSummary(gauge) : undefined
  return (
    <span ref={anchor} className={styles.anchor}>
      <button type="button" className={styles.button} data-open={open || undefined} aria-label="Context"
        aria-valuetext={summary} aria-expanded={open} title={summary ? `Context: ${summary}` : 'Token use'}
        onClick={() => setOpen(!open)}>
        <Ring fraction={gauge ? gaugeFraction(gauge) : 0} />
        {gauge && <span className={styles.percent}>{gauge.isEstimated ? '~' : ''}{gauge.percent}%</span>}
      </button>
      {open && <ContextDetails gauge={gauge} breakdown={usage.breakdown} usage={usage.usage} />}
    </span>
  )
}

/** A ring that fills clockwise from the top; orange past 80 %, red past 95 %, as the context nears compression. */
function Ring({ fraction }: { fraction: number }) {
  const tone = fraction > 0.95 ? 'full' : fraction > 0.8 ? 'warn' : 'normal'
  const radius = 6
  const length = 2 * Math.PI * radius
  return (
    <svg className={styles.ring} viewBox="0 0 16 16" aria-hidden="true" data-tone={tone}>
      <circle className={styles.track} cx="8" cy="8" r={radius} />
      <circle className={styles.fill} cx="8" cy="8" r={radius} strokeDasharray={`${fraction * length} ${length}`}
        transform="rotate(-90 8 8)" />
    </svg>
  )
}

/** The gauge's panel: the context, what fills it, then the session's counters. */
function ContextDetails({ gauge, breakdown, usage }: { gauge?: Gauge; breakdown?: ContextBreakdown; usage?: SessionUsage }) {
  const unitemized = gauge && breakdown && !gauge.isEstimated ? unitemizedTokens(breakdown, gauge.used) : 0
  return (
    <div className={styles.panel} role="dialog" aria-label="Context details">
      {gauge && (
        <section className={styles.section}>
          <h3 className={styles.heading}>Context</h3>
          <div className={styles.bar} data-tone={gaugeFraction(gauge) > 0.8 ? 'warn' : 'normal'}>
            <div className={styles.barFill} style={{ width: `${gaugeFraction(gauge) * 100}%` }} />
          </div>
          <div className={styles.value}>{contextSummary(gauge)}</div>
          {gauge.isEstimated && <div className={styles.caption}>Estimated until a reply measures it.</div>}
        </section>
      )}
      {breakdown && breakdown.categories.length > 0 && (
        <section className={styles.section}>
          {breakdown.categories.map((category) => <Row key={category.id} label={category.label} value={`~${formatTokens(category.tokens)}`} />)}
          {unitemized > 0 && <Row label="Not itemized" value={`~${formatTokens(unitemized)}`} />}
          {gauge && !gauge.isEstimated && <div className={styles.caption}>Items are estimates. The total is the model's own count.</div>}
        </section>
      )}
      {usage && (
        <section className={gauge ? styles.sessionSection : styles.section}>
          <h3 className={styles.heading}>This Session</h3>
          <Row label="Tokens" value={`${formatTokens(usage.total)} (${formatTokens(usage.input)} in · ${formatTokens(usage.output)} out)`} />
          <Row label="Model calls" value={usage.calls.toLocaleString('en-US')} />
          {usage.cacheHitPercent !== undefined && <Row label="Cache hits" value={`${usage.cacheHitPercent}%`} />}
          {usage.tokensPerSecond !== undefined && <Row label="Speed" value={`${Math.round(usage.tokensPerSecond)} tokens/s`} />}
          {usage.compressions !== undefined && usage.compressions > 0 && <Row label="Compressions" value={usage.compressions.toLocaleString('en-US')} />}
          {usage.costUSD !== undefined && usage.costUSD > 0 && <Row label="Cost" value={usd.format(usage.costUSD)} />}
        </section>
      )}
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className={styles.row}>
      <span className={styles.label}>{label}</span>
      <span className={styles.number}>{value}</span>
    </div>
  )
}
