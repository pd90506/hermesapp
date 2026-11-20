import { useEffect, useState } from 'react'
import { backgroundTitle, describeError, type BackgroundProcess, type ChatSession } from '@talaria/hermes-core'
import { useSnapshot } from '../../../app/hooks.ts'
import type { ChatPillProps } from '../overlay.ts'
import { useOpenCard } from './open-card.ts'
import { Chevron, PillButton, PillCard, Spinner } from './PillCard.tsx'
import styles from './Pills.module.css'

/**
 * The processes the chat's agent left running in the background
 * (`ChatActivity.processes`), as Desktop's status stack lists them: a pill
 * ("1 background task"), which opens into a card. Each row shows its command and how it
 * ended; picked, its newest output. A running one has Stop, a finished one goes by
 * itself after a few seconds, or with its ✕.
 */
export function BackgroundPill({ chat }: ChatPillProps) {
  const { processes: list } = useSnapshot(chat.activity)
  const processes = list.processes
  const [open, setOpen] = useOpenCard(chat, 'background')
  useEffect(() => chat.activity.watch(), [chat])
  useEffect(() => { if (processes.length === 0 && open) setOpen(false) }, [processes.length, open, setOpen])
  if (processes.length === 0) return null
  const running = processes.filter((process) => process.state === 'running').length
  const failed = processes.some((process) => process.state === 'failed')
  const icon = running > 0 ? <Spinner /> : failed ? <FailedMark /> : <DoneMark />
  return (
    <div className={styles.slot}>
      <PillButton icon={icon} title={backgroundTitle(running > 0 ? running : processes.length)}
        label={running > 0 ? `${backgroundTitle(running)} running` : backgroundTitle(processes.length)}
        hint="Shows the background tasks" open={open} onToggle={() => setOpen(!open)} testID="backgroundProcessesPill" />
      {open && (
        <PillCard title={backgroundTitle(processes.length)} onClose={() => setOpen(false)} testID="backgroundProcessesPanel">
          <ul className={styles.rows}>
            {processes.map((process) => <ProcessRow key={process.id} chat={chat} process={process} />)}
          </ul>
        </PillCard>
      )}
    </div>
  )
}

function ProcessRow({ chat, process }: { chat: ChatSession; process: BackgroundProcess }) {
  const [picked, setPicked] = useState(false)
  const [stopping, setStopping] = useState(false)
  const [stopError, setStopError] = useState<string>()
  const stop = () => {
    setStopping(true)
    setStopError(undefined)
    chat.activity.stopBackgroundProcess(process.id)
      .catch((error: unknown) => setStopError(`Hermes couldn't stop it. Try again. (${describeError(error)})`))
      .finally(() => setStopping(false))
  }
  return (
    <li className={styles.row}>
      <div className={styles.rowLine}>
        <button type="button" className={styles.rowButton} aria-expanded={process.output ? picked : undefined}
          onClick={() => setPicked(!picked)} data-testid="backgroundProcessRow">
          <span className={styles.rowIcon}>
            {process.state === 'running' ? <Spinner /> : process.state === 'failed' ? <FailedMark /> : <DoneMark />}
          </span>
          <span className={styles.command} data-picked={picked || undefined}>{process.title}</span>
          {process.state === 'failed' && process.exitCode !== undefined && <span className={styles.exitCode}>exit {process.exitCode}</span>}
          {process.output && <Chevron open={picked} />}
        </button>
        {process.state === 'running'
          ? <button type="button" className={styles.danger} disabled={stopping} onClick={stop} data-testid="backgroundProcessStop">Stop</button>
          : (
            <button type="button" className={styles.dismiss} aria-label="Dismiss" title="Dismiss"
              onClick={() => chat.activity.dismissBackgroundProcess(process.id)}>
              <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" /></svg>
            </button>
          )}
      </div>
      {stopError && <p className={styles.error}>{stopError}</p>}
      {picked && process.output && <pre className={styles.output}>{process.output.split('\n').slice(-12).join('\n')}</pre>}
    </li>
  )
}

function DoneMark() {
  return <svg className={styles.done} viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.5" /><path d="M5.2 8.2 7.1 10 10.8 6.2" /></svg>
}

function FailedMark() {
  return <svg className={styles.failed} viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.5" /><path d="M5.8 5.8l4.4 4.4M10.2 5.8l-4.4 4.4" /></svg>
}
