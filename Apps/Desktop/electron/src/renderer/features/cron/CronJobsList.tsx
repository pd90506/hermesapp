import { useCallback, useEffect, useState, type MouseEvent as ReactMouseEvent } from 'react'
import {
  cronJobTitle, cronRunTime, deliveryLabel, deliveryOptionTitle, deliveryOptions, deliveryTargets, effectiveState,
  isInactive, isOutputDocument, isPaused, isRunning, lastRunProblem, overdueSince, toggleDelivery,
  type CronBoard, type CronDeliveryTarget, type CronJob, type CronRun, type CronSnapshot,
} from '@talaria/hermes-core'
import { useSnapshot } from '../../app/hooks.ts'
import { CronIcon } from './CronIcon.tsx'
import { CronJobEditor, type CronEditorTarget } from './CronJobEditor.tsx'
import { CronMenu, type CronMenuItem } from './CronMenu.tsx'
import { Confirm } from '../settings/providers/controls.tsx'
import { capitalized, relativeTo, runTime, shortTime } from './format.ts'
import { useCronBoard } from './board.ts'
import styles from './CronJobsList.module.css'

/** How often the tab re-reads while it shows: the session list's pace (the Mac's 15 s). */
export const cronRefreshMs = 15_000

/**
 * The selected profile's scheduled jobs (the Cron Jobs tab), as the Mac's `CronJobsList`
 * (Desktop's sidebar Cron section, `apps/desktop/src/app/chat/sidebar/cron-jobs-section.tsx`).
 * A job's row shows its schedule, where it delivers and when it runs next; a click shows
 * its recent runs under it, one job at a time. Run Now, Edit…, Pause or Resume, Deliver To
 * and Delete… are in its "…" menu and its right-click menu; New Cron Job is the row above
 * the jobs. `onOpenRun` opens an agent run as a read-only chat (wired once chats land).
 */
export function CronJobsList({ onOpenRun, selectedRun }: {
  onOpenRun?: (run: CronRun, profile: string) => void
  selectedRun?: string
}) {
  const { board, connection } = useCronBoard()
  const link = useSnapshot(connection).link.phase
  const profile = useSnapshot(connection).selectedProfile
  return (
    <CronJobsView board={board} connected={link === 'connected'} listProfile={profile}
      {...(onOpenRun ? { onOpenRun } : {})} {...(selectedRun ? { selectedRun } : {})} />
  )
}

/** The tab's content over a board: what `CronJobsList` shows, apart from where the board comes from. */
export function CronJobsView({ board, connected, listProfile, onOpenRun, selectedRun, now: fixedNow }: {
  board: CronBoard
  connected: boolean
  listProfile: string | undefined
  onOpenRun?: (run: CronRun, profile: string) => void
  selectedRun?: string
  /** A fixed time to count from (tests, screenshots); otherwise moved on with each re-read. */
  now?: number
}) {
  const cron = useSnapshot(board)
  const [expanded, setExpanded] = useState<string>()
  const [menu, setMenu] = useState<{ job: CronJob; at: { x: number; y: number } }>()
  const [editing, setEditing] = useState<CronEditorTarget>()
  const [deleting, setDeleting] = useState<CronJob>()
  const [actionError, setActionError] = useState<string>()
  const [now, setNow] = useState(() => fixedNow ?? Date.now())
  const expandedRef = useLatest(expanded)

  useEffect(() => {
    // While the tab shows: the jobs and the open job's runs, re-read on the session
    // list's pace (Desktop's peek polls every 8 s, the Mac every 15 s).
    if (!connected || listProfile === undefined) return
    let stopped = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const tick = async () => {
      await board.refreshJobs()
      await board.loadDeliveryTargets()
      if (stopped) return
      if (fixedNow === undefined) setNow(Date.now())
      const job = board.get().jobs.find((item) => item.id === expandedRef.current)
      if (job) await board.refreshRuns(job)
      if (!stopped) timer = setTimeout(() => void tick(), cronRefreshMs)
    }
    void tick()
    return () => {
      stopped = true
      clearTimeout(timer)
    }
    // `isAvailable`: the board's source arrives after this first read on a new connection.
  }, [board, connected, listProfile, fixedNow, cron.isAvailable])

  const perform = useCallback((action: () => Promise<void>) => {
    action().then(() => setActionError(undefined), (error: unknown) => {
      setActionError(error instanceof Error ? error.message : String(error))
    })
  }, [])

  const toggle = (job: CronJob) => {
    if (expanded === job.id) {
      setExpanded(undefined)
      return
    }
    setExpanded(job.id)
    void board.refreshRuns(job)
  }

  const isCurrent = cron.profile !== undefined && cron.profile === listProfile
  const canCreate = connected && cron.isAvailable && isCurrent

  const items = (job: CronJob): CronMenuItem[] => [
    { kind: 'action', id: 'runNow', label: 'Run Now', disabled: !connected || cron.triggering.includes(job.id), onSelect: () => {
      setExpanded(job.id)
      perform(() => board.trigger(job))
    } },
    { kind: 'action', id: 'edit', label: 'Edit…', disabled: !connected, onSelect: () => setEditing({ kind: 'edit', job }) },
    isPaused(job)
      ? { kind: 'action', id: 'resume', label: 'Resume', disabled: !connected, onSelect: () => perform(() => board.resume(job)) }
      : { kind: 'action', id: 'pause', label: 'Pause', disabled: !connected, onSelect: () => perform(() => board.pause(job)) },
    { kind: 'submenu', label: 'Deliver To', disabled: !connected, items: deliveryOptions(cron.targets, job.deliver).map((target) => ({
      kind: 'toggle' as const,
      label: deliveryOptionTitle(target),
      checked: deliveryTargets(job).includes(target.id),
      onToggle: (on: boolean) => {
        const deliver = toggleDelivery(job.deliver, target.id, on)
        if (deliver !== job.deliver) perform(() => board.setDelivery(job, deliver))
      },
    })) },
    { kind: 'divider' },
    { kind: 'action', id: 'delete', label: 'Delete…', destructive: true, disabled: !connected, onSelect: () => setDeleting(job) },
  ]

  const openMenu = (job: CronJob, event: ReactMouseEvent, fromButton: boolean) => {
    event.preventDefault()
    event.stopPropagation()
    if (fromButton) {
      const rect = (event.currentTarget as HTMLElement).getBoundingClientRect()
      setMenu({ job, at: { x: rect.left, y: rect.bottom } })
    } else {
      setMenu({ job, at: { x: event.clientX, y: event.clientY } })
    }
  }

  return (
    <section className={styles.pane} aria-label="Cron Jobs">
      <div className={styles.list} role="list">
        <h2 className={styles.section}>Cron Jobs</h2>
        {body()}
      </div>
      {menu && (
        <CronMenu label={`${cronJobTitle(menu.job)} actions`} items={items(menu.job)} at={menu.at}
          onClose={() => setMenu(undefined)} />
      )}
      {editing && (
        <CronJobEditor target={editing} board={board} onClose={() => setEditing(undefined)} />
      )}
      <Confirm open={deleting !== undefined} title={`Delete “${deleting ? cronJobTitle(deleting) : 'this job'}”?`}
        message="The job is removed from Hermes and won't run again." action="Delete"
        onClose={() => setDeleting(undefined)}
        onConfirm={() => {
          const job = deleting
          if (!job) return
          if (expanded === job.id) setExpanded(undefined)
          perform(() => board.delete(job))
        }} />
    </section>
  )

  function body() {
    if (!connected) return <p className={styles.note}>Connect to see scheduled jobs</p>
    if (!cron.isAvailable) return <p className={styles.note}>This connection can't read scheduled jobs.</p>
    if (!isCurrent || (cron.isLoading && cron.jobs.length === 0)) {
      return <p className={styles.loading} role="status">Loading jobs…</p>
    }
    return (
      <>
        <button type="button" className={styles.newJob} disabled={!canCreate} data-testid="newCronJob"
          onClick={() => setEditing({ kind: 'new' })}>
          <CronIcon name="add" />
          <span>New Cron Job</span>
        </button>
        {actionError && <p className={styles.error} role="alert">{actionError}</p>}
        {cron.error && (
          <div className={styles.errorBlock}>
            <p className={styles.error}>{cron.error}</p>
            <button type="button" className={styles.retry} onClick={() => void board.refreshJobs()}>Retry</button>
          </div>
        )}
        {cron.jobs.length === 0 && !cron.error && (
          <div className={styles.empty}>
            <span>No cron jobs</span>
            <span className={styles.caption}>
              Make one with New Cron Job, or ask Hermes in a chat, such as “every morning at 9, summarize the news”.
            </span>
          </div>
        )}
        {cron.jobs.map((job) => (
          <div key={job.id} className={styles.group}>
            <JobRow job={job} expanded={expanded === job.id} running={cron.triggering.includes(job.id)}
              targets={cron.targets} now={now} onToggle={() => toggle(job)}
              onMenu={(event, fromButton) => openMenu(job, event, fromButton)} />
            {expanded === job.id && (
              <RunRows job={job} cron={cron}
                {...(onOpenRun ? { onOpenRun } : {})} {...(selectedRun ? { selectedRun } : {})} />
            )}
          </div>
        ))}
      </>
    )
  }
}

function useLatest<T>(value: T): { readonly current: T } {
  const [ref] = useState(() => ({ current: value }))
  ref.current = value
  return ref
}

/**
 * A job: a chevron, a state dot, its title and when it runs next (or why it won't);
 * under them its schedule and where it delivers, and the last run's error, if it failed.
 */
function JobRow({ job, expanded, running, targets, now, onToggle, onMenu }: {
  job: CronJob
  expanded: boolean
  running: boolean
  targets: readonly CronDeliveryTarget[]
  now: number
  onToggle: () => void
  onMenu: (event: ReactMouseEvent, fromButton: boolean) => void
}) {
  const overdue = overdueSince(job, now)
  const problem = lastRunProblem(job)
  const delivery = deliveryTargets(job).map((id) => deliveryLabel(id, targets)).join(', ')
  const details = [job.scheduleDisplay, `→ ${delivery}`].filter(Boolean).join('  ')
  return (
    <div className={styles.job} role="listitem" data-testid={`cronJob.${job.id}`}
      onContextMenu={(event) => onMenu(event, false)}>
      <button type="button" className={styles.summary} aria-expanded={expanded}
        title={expanded ? 'Hides its runs' : 'Shows its runs'} onClick={onToggle}>
        <span className={styles.chevron}><CronIcon name={expanded ? 'chevronDown' : 'chevronRight'} /></span>
        <span className={styles.dot} data-state={dotState(job)} />
        <span className={styles.text}>
          <span className={styles.line}>
            <span className={styles.title}>{cronJobTitle(job)}</span>
            <span className={styles.meta} data-overdue={overdue !== undefined || undefined}>
              {meta(job, running, overdue, now)}
            </span>
          </span>
          <span className={styles.details}>{details}</span>
          {problem && <span className={styles.problem}>{problem}</span>}
        </span>
      </button>
      <button type="button" className={styles.more} title="More" aria-label="More actions"
        data-testid={`cronJobMenu.${job.id}`} onClick={(event) => onMenu(event, true)}>
        <CronIcon name="more" />
      </button>
    </div>
  )
}

/** When it runs next, or its state when it isn't waiting to. */
function meta(job: CronJob, running: boolean, overdue: number | undefined, now: number) {
  if (running || isRunning(job)) {
    return <><span className={styles.spinner} aria-hidden="true" />Running</>
  }
  if (isInactive(job)) return capitalized(effectiveState(job))
  if (overdue !== undefined) return `Overdue since ${shortTime(overdue)}`
  if (job.nextRunAt !== undefined) return relativeTo(job.nextRunAt, now)
  return null
}

function dotState(job: CronJob): string {
  switch (effectiveState(job)) {
    case 'paused': return 'paused'
    case 'error': return 'error'
    case 'completed':
    case 'disabled': return 'off'
    default: return 'on'
  }
}

/**
 * The job's recent runs, newest first, set in under it. A run with a session opens it as
 * a chat; a script-only run shows the start of its output. An agent run's preview is the
 * scheduler's own instructions, so it shows only the time, as in Desktop
 * (`cron-jobs-section.tsx:490-520`).
 */
function RunRows({ job, cron, onOpenRun, selectedRun }: {
  job: CronJob
  cron: CronSnapshot
  onOpenRun?: (run: CronRun, profile: string) => void
  selectedRun?: string
}) {
  const runs = cron.runs[job.id]
  const error = cron.runErrors[job.id]
  if (!runs) {
    if (error) return <p className={`${styles.runNote} ${styles.runError}`}>{error}</p>
    return <p className={styles.runNote} role="status"><span className={styles.spinner} aria-hidden="true" /></p>
  }
  if (runs.length === 0) {
    return <p className={`${styles.runNote} ${error ? styles.runError : ''}`}>{error ?? 'No runs yet'}</p>
  }
  return runs.map((run) => {
    const time = runTime(cronRunTime(run))
    if (isOutputDocument(run)) {
      const preview = run.preview?.trim()
      return (
        <div key={run.id} className={styles.output} role="listitem">
          <span className={styles.outputTime}>{time}</span>
          {preview && <span className={styles.outputPreview}>{preview}</span>}
        </div>
      )
    }
    const profile = run.profile ?? cron.profile ?? ''
    return (
      <button key={run.id} type="button" role="listitem" className={styles.run} data-testid={`cronRun.${run.id}`}
        aria-selected={selectedRun === run.id} disabled={!onOpenRun}
        onClick={() => onOpenRun?.(run, profile)}>
        {time}
      </button>
    )
  })
}
