import { useEffect, useState } from 'react'
import type { ChatSession, SubagentActivityKind, SubagentRun } from '@talaria/hermes-core'
import { useSnapshot } from '../../../app/hooks.ts'
import type { ChatPillProps } from '../overlay.ts'
import { useOpenCard } from './open-card.ts'
import { Chevron, PillButton, PillCard, Spinner } from './PillCard.tsx'
import styles from './Pills.module.css'

export const subagentsTitle = (count: number): string => count === 1 ? '1 subagent' : `${count} subagents`

/**
 * The chat's running subagents (`ChatActivity.subagents`), as Desktop's status stack
 * lists them: a pill ("2 subagents", spinning), which opens into a card. Each child
 * shows its goal, what it did last and how long it has run; picked, its newest lines, a
 * field to steer it and Stop. It goes once no child runs.
 */
export function SubagentsPill({ chat }: ChatPillProps) {
  const { subagents } = useSnapshot(chat.activity)
  const live = subagents.live
  const [open, setOpen] = useOpenCard(chat, 'subagents')
  const [picked, setPicked] = useState<string>()
  /** What is typed to steer each child, kept while another is picked. */
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  useEffect(() => chat.activity.watch(), [chat])
  useEffect(() => { if (live.length === 0 && open) setOpen(false) }, [live.length, open, setOpen])
  useEffect(() => { if (picked && !live.some((run) => run.id === picked)) setPicked(undefined) }, [live, picked])
  if (live.length === 0) return null
  const title = subagentsTitle(live.length)
  return (
    <div className={styles.slot}>
      <PillButton icon={<Spinner />} title={title} label={`${title} running`} hint="Shows the subagents" open={open}
        onToggle={() => setOpen(!open)} testID="subagentsPill" />
      {open && (
        <PillCard title={title} onClose={() => setOpen(false)} testID="subagentsPanel">
          <ul className={styles.rows}>
            {live.map((run) => (
              <li key={run.id} className={styles.row}>
                <SubagentRow run={run} picked={picked === run.id} onToggle={() => setPicked(picked === run.id ? undefined : run.id)} />
                {picked === run.id && (
                  <SubagentDetail chat={chat} run={run} draft={drafts[run.id] ?? ''}
                    onDraft={(text) => setDrafts((all) => ({ ...all, [run.id]: text }))} />
                )}
              </li>
            ))}
          </ul>
        </PillCard>
      )}
    </div>
  )
}

function SubagentRow({ run, picked, onToggle }: { run: SubagentRun; picked: boolean; onToggle: () => void }) {
  const latest = run.activity.at(-1)?.text ?? (run.status === 'queued' ? 'Queued' : 'Waiting for activity…')
  return (
    <button type="button" className={styles.rowButton} aria-expanded={picked} onClick={onToggle} data-testid="subagentRow">
      <span className={styles.rowIcon}><Spinner /></span>
      <span className={styles.goal}>
        <span className={styles.goalText} data-picked={picked || undefined}>{run.goal}</span>
        <span className={styles.latest}>{latest}</span>
      </span>
      <Elapsed since={run.startedAt} />
      <Chevron open={picked} />
    </button>
  )
}

/** How long the child has run, counting up by itself ("1:05"). */
function Elapsed({ since }: { since: number }) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [])
  return <span className={styles.elapsed}>{elapsed(now - since)}</span>
}

export function elapsed(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = String(seconds % 60).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`
}

/** A picked child: its newest lines, then a field to steer it and Stop. */
function SubagentDetail({ chat, run, draft, onDraft }: { chat: ChatSession; run: SubagentRun; draft: string; onDraft: (text: string) => void }) {
  const [sending, setSending] = useState(false)
  const [feedback, setFeedback] = useState<{ text: string; failed: boolean }>()
  const send = (done: string, call: () => Promise<boolean>) => {
    setSending(true)
    setFeedback(undefined)
    call().catch(() => false).then((accepted) => {
      setFeedback(accepted ? { text: done, failed: false } : { text: "Hermes didn't accept that: the subagent may have finished.", failed: true })
    }).finally(() => setSending(false))
  }
  const steer = () => {
    const text = draft
    if (sending || text.trim() === '') return
    send('It will read that with its next tool result.', async () => {
      const queued = await chat.activity.steerSubagent(run.id, text)
      if (queued) onDraft('')
      return queued
    })
  }
  return (
    <div className={styles.detail}>
      {run.activity.length > 0 && (
        <ul className={styles.activity}>
          {run.activity.slice(-6).map((line, index) => (
            <li key={index} className={styles.activityLine} data-error={line.isError || undefined}>
              <ActivityIcon kind={line.kind} />
              <span className={styles.activityText}>{line.text}</span>
            </li>
          ))}
        </ul>
      )}
      <div className={styles.steer}>
        <input className={styles.steerField} value={draft} placeholder="Steer this subagent…" disabled={sending}
          aria-label="Steer this subagent" data-testid="subagentSteerField"
          onChange={(event) => onDraft(event.target.value)}
          onKeyDown={(event) => { if (event.key === 'Enter' && !event.nativeEvent.isComposing) steer() }} />
        <button type="button" className={styles.button} disabled={sending || draft.trim() === ''} onClick={steer}>Steer</button>
        <button type="button" className={styles.danger} disabled={sending} data-testid="subagentStop"
          onClick={() => send('Asked it to stop.', () => chat.activity.stopSubagent(run.id))}>Stop</button>
      </div>
      {feedback && <p className={feedback.failed ? styles.error : styles.note}>{feedback.text}</p>}
    </div>
  )
}

function ActivityIcon({ kind }: { kind: SubagentActivityKind }) {
  const paths: Record<SubagentActivityKind, string> = {
    tool: 'M10.2 2.6a3 3 0 0 0-3.5 4L2.8 10.5a1.2 1.2 0 0 0 1.7 1.7l3.9-3.9a3 3 0 0 0 4-3.5L10.6 6.6 9 6.2l-.4-1.6z',
    progress: 'M3 8h9M9 4.5 12.5 8 9 11.5',
    thinking: 'M8 2.5a4 4 0 0 0-2.5 7.1V11h5V9.6A4 4 0 0 0 8 2.5zM6 13h4',
    summary: 'M3 4h10M3 7h10M3 10h6',
  }
  return <svg className={styles.activityIcon} viewBox="0 0 16 16" aria-hidden="true"><path d={paths[kind]} /></svg>
}
