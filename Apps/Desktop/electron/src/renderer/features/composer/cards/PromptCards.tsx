import { useEffect } from 'react'
import type { HeldPrompt, TranscriptItem } from '@talaria/hermes-core'
import { useConnection, useSnapshot } from '../../../app/hooks.ts'
import type { ComposerSlotProps } from '../slots.ts'
import styles from './PromptCards.module.css'

/**
 * Over the composer (the Mac's `ComposerView` bubbles, PR #144 / #145): "Compressing
 * context…" while a compression runs, the prompts Hermes queued, then the messages held
 * here while a reply or a compression runs, each its own card as wide as the composer,
 * the newest nearest it. A held one can be steered into the running reply (↪) or taken
 * back into the composer (✕).
 */
export function PromptCards({ chat, composer }: ComposerSlotProps) {
  const queue = composer.queue
  const { held, isCompressing } = useSnapshot(queue)
  const view = useSnapshot(chat)
  const link = useSnapshot(useConnection()).link
  const isConnected = link.phase === 'connected'
  // Back online: a held message that could not go out tries again.
  useEffect(() => { if (isConnected) queue.retry() }, [isConnected, queue])
  const compressing = isCompressing || view.isCompacting
  const canSteer = view.isRunning && !compressing
  if (!compressing && view.queuedPrompts.length === 0 && held.length === 0) return null
  return (
    <div className={styles.stack}>
      {compressing && (
        <div className={styles.card} role="status" data-card="compressing">
          <span className={styles.spinner} aria-hidden="true" />
          <span className={styles.text}>Compressing context…</span>
        </div>
      )}
      {view.queuedPrompts.map((item) => <QueuedCard key={item.id} item={item} />)}
      {held.map((prompt) => (
        <HeldCard key={prompt.id} prompt={prompt} canSteer={canSteer && isConnected}
          onSteer={() => void queue.steer(prompt.id)} onCancel={() => queue.cancel(prompt.id)} />
      ))}
    </div>
  )
}

/** A prompt in Hermes's queue that no turn has taken yet; it moves into the chat when its turn starts. */
function QueuedCard({ item }: { item: TranscriptItem }) {
  const label = oneLine(item.text || item.attachments.join(', '))
  return (
    <div className={styles.card} aria-label={`Queued: ${label}`} data-card="queued">
      <ClockIcon />
      <span className={styles.text}>{label}</span>
    </div>
  )
}

function HeldCard({ prompt, canSteer, onSteer, onCancel }: {
  prompt: HeldPrompt
  canSteer: boolean
  onSteer: () => void
  onCancel: () => void
}) {
  return (
    <div className={styles.card} data-card="held">
      <ClockIcon />
      <span className={styles.text} aria-label={`Queued: ${prompt.text}`}>{oneLine(prompt.text)}</span>
      {canSteer && (
        <button type="button" className={styles.action} aria-label="Steer Now"
          title="Send it into the current reply now, as a steer" onClick={onSteer}>
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M9.5 4.5 13 8l-3.5 3.5M13 8H6.5A3.5 3.5 0 0 0 3 11.5V12" /></svg>
        </button>
      )}
      <button type="button" className={styles.action} aria-label="Cancel"
        title="Cancel it and put the text back in the message box" onClick={onCancel}>
        <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" /></svg>
      </button>
    </div>
  )
}

function ClockIcon() {
  return (
    <svg className={styles.icon} viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 2.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM8 5v3.2l2 1.3" />
    </svg>
  )
}

/** The first 200 characters on one line; the card truncates the rest with an ellipsis. */
function oneLine(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > 200 ? `${flat.slice(0, 200)}…` : flat
}
