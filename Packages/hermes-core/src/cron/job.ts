import type { JSONValue } from '../protocol/jsonrpc.ts'

// Scheduled jobs on the dashboard's REST routes (`hermes_cli/web_routers/cron.py`), a
// port of HermesKit's `Cron/CronJob.swift`, behaviour for behaviour.

/**
 * A scheduled job, as `GET /api/cron/jobs?profile=` lists it (`cron/jobs.py::create_job`,
 * `hermes_cli/web_routers/cron.py:110-152`). Read field by field (`parseCronJob`), so a
 * field of an unexpected type drops that field, not the whole list.
 */
export interface CronJob {
  id: string
  name?: string
  prompt?: string
  script?: string
  /** The script is the whole job: no agent, so no run sessions, only output documents. */
  noAgent: boolean
  /** Comma-separated delivery targets (`local`, `origin`, `bot-chat`, `telegram:123`, …). */
  deliver?: string
  enabled: boolean
  /** `scheduled`, `running`, `paused`, `completed`, `error`, … (open set). */
  state?: string
  /** The schedule as written for people (`"every 2h"`, `"0 9 * * *"`). */
  scheduleDisplay?: string
  /** Milliseconds since the epoch. */
  nextRunAt?: number
  lastRunAt?: number
  /** `ok`, `error`, `delivery_failed`, `blocked_config`, … (open set). */
  lastStatus?: string
  lastError?: string
  lastDeliveryError?: string
  pausedReason?: string
  /**
   * The schedule as the editor takes it back: the cron expression, else the display form
   * (`"every 2h"`), which the scheduler parses too (`apps/desktop/src/app/cron/index.tsx::jobScheduleExpr`).
   */
  scheduleExpression?: string
  /** The job's own model and provider, when it pins one; undefined follows the default. */
  model?: string
  provider?: string
}

type JSONObject = { [key: string]: JSONValue }

function asObject(value: unknown): JSONObject | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JSONObject : undefined
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

/** A job with defaults filled in, for tests and for the editor's scratch jobs. */
export function cronJob(fields: Partial<CronJob> & { id: string }): CronJob {
  const job: CronJob = { noAgent: false, enabled: true, ...fields }
  if (job.scheduleExpression === undefined && job.scheduleDisplay !== undefined) job.scheduleExpression = job.scheduleDisplay
  return job
}

/** Reads one listed job; undefined for a row without an id. */
export function parseCronJob(value: unknown): CronJob | undefined {
  const json = asObject(value)
  if (!json) return undefined
  const id = asString(json.id) ?? asString(json.job_id)
  if (id === undefined) return undefined
  const text = (key: string): string | undefined => {
    const item = asString(json[key])?.trim()
    return item ? item : undefined
  }
  const schedule = json.schedule
  const scheduleObject = asObject(schedule)
  const job: CronJob = { id, noAgent: json.no_agent === true, enabled: typeof json.enabled === 'boolean' ? json.enabled : true }
  const set = <K extends keyof CronJob>(key: K, item: CronJob[K] | undefined) => {
    if (item !== undefined) job[key] = item
  }
  set('name', text('name'))
  set('prompt', text('prompt'))
  set('script', text('script'))
  // Stored as a string; a list is joined the way the scheduler splits it.
  if (Array.isArray(json.deliver)) {
    set('deliver', json.deliver.filter((item): item is string => typeof item === 'string').join(','))
  } else {
    set('deliver', text('deliver'))
  }
  set('state', text('state'))
  set('scheduleDisplay', text('schedule_display') ?? asString(scheduleObject?.display)
    ?? asString(scheduleObject?.expr) ?? asString(schedule))
  set('nextRunAt', parseCronDate(text('next_run_at')))
  set('lastRunAt', parseCronDate(text('last_run_at')))
  set('lastStatus', text('last_status'))
  set('lastError', text('last_error'))
  set('lastDeliveryError', text('last_delivery_error'))
  set('pausedReason', text('paused_reason'))
  const expr = asString(scheduleObject?.expr)
  set('scheduleExpression', expr ? expr : job.scheduleDisplay)
  set('model', text('model'))
  set('provider', text('provider'))
  return job
}

/** Reads a job list, dropping rows that are not jobs. */
export function parseCronJobs(value: unknown): CronJob[] {
  return Array.isArray(value) ? value.map(parseCronJob).filter((job): job is CronJob => job !== undefined) : []
}

/**
 * A script that runs without an agent: no prompt needed, and no model to pick
 * (`jobIsScriptOnly`, `apps/desktop/src/app/cron/cron-job-model.ts:8-10`).
 */
export function isScriptOnly(job: CronJob): boolean {
  return job.noAgent && job.script !== undefined
}

/**
 * Desktop's `jobTitle`: the name, else the start of the prompt, else of the script,
 * else the id (`apps/desktop/src/app/cron/job-state.ts:38-46`).
 */
export function cronJobTitle(job: CronJob): string {
  if (job.name) return job.name
  if (job.prompt) return truncated(job.prompt, 60)
  if (job.script) return truncated(job.script, 60)
  return job.id
}

/** The stated state, else one from `enabled` (`job-state.ts:16-20`). */
export function effectiveState(job: CronJob): string {
  return job.state ?? (job.enabled ? 'scheduled' : 'disabled')
}

export function isPaused(job: CronJob): boolean {
  return effectiveState(job) === 'paused'
}

export function isRunning(job: CronJob): boolean {
  return effectiveState(job) === 'running'
}

/** States in which the job is not waiting to fire. */
export function isInactive(job: CronJob): boolean {
  return ['completed', 'disabled', 'error', 'paused'].includes(effectiveState(job))
}

/**
 * When `next_run_at` passed more than 15 minutes ago, the sign of a scheduler that
 * stopped ticking: never shown as an upcoming run (`job-state.ts:48-69`,
 * `hermes_cli/cron.py::_OVERDUE_GRACE_SECONDS`).
 */
export function overdueSince(job: CronJob, now: number = Date.now()): number | undefined {
  if (['paused', 'completed', 'disabled'].includes(effectiveState(job))) return undefined
  const next = job.nextRunAt
  return next !== undefined && now - next > 15 * 60 * 1000 ? next : undefined
}

/** Jobs whose last run failed or wasn't delivered (the Cron Jobs tab's red dot). */
export function needsAttention(job: CronJob): boolean {
  return ['error', 'blocked_config', 'delivery_failed'].includes(job.lastStatus ?? '')
}

/** The last run's failure, as the scheduler recorded it. */
export function lastRunProblem(job: CronJob): string | undefined {
  switch (job.lastStatus) {
    case 'error':
    case 'blocked_config': return job.lastError ? `Last run failed: ${job.lastError}` : 'Last run failed'
    case 'delivery_failed': return job.lastDeliveryError ? `Not delivered: ${job.lastDeliveryError}` : 'Not delivered'
    default: return undefined
  }
}

/** The comma list of targets, unique, in order; `["local"]` when empty (`cron-job-model.ts:84-91`). */
export function parseTargets(value: string | undefined): string[] {
  const seen = new Set<string>()
  const targets = (value ?? '').split(',').map((item) => item.trim())
    .filter((item) => item !== '' && !seen.has(item) && (seen.add(item), true))
  return targets.length ? targets : ['local']
}

/** The job's delivery targets, `local` when it names none. */
export function deliveryTargets(job: Pick<CronJob, 'deliver'>): string[] {
  return parseTargets(job.deliver)
}

/** Whether the job's output lands in a Bot Chat (`bot-chat` or `bot-chat:<profile>`). */
export function deliversToBotChat(job: CronJob): boolean {
  return deliveryTargets(job).some((target) => target === botChatTarget || target.startsWith(`${botChatTarget}:`))
}

/**
 * `deliver` with `target` turned on or off. The last target stays: a job always
 * delivers somewhere (`toggleCronDeliveryTarget`, `cron-job-model.ts:93-105`).
 */
export function toggleDelivery(deliver: string | undefined, target: string, on: boolean): string {
  const targets = parseTargets(deliver)
  if (on) return (targets.includes(target) ? targets : [...targets, target]).join(',')
  if (!targets.includes(target) || targets.length <= 1) return targets.join(',')
  return targets.filter((item) => item !== target).join(',')
}

/**
 * Soonest next run first, jobs with none last, then by title (Desktop's sidebar order,
 * `cron-jobs-section.tsx:154-175`).
 */
export function cronListOrder(jobs: readonly CronJob[]): CronJob[] {
  return [...jobs].sort((a, b) => {
    const x = a.nextRunAt
    const y = b.nextRunAt
    if (x !== undefined && y !== undefined && x !== y) return x - y
    if (x === undefined && y !== undefined) return 1
    if (x !== undefined && y === undefined) return -1
    return cronJobTitle(a).localeCompare(cronJobTitle(b), undefined, { numeric: true, sensitivity: 'base' })
  })
}

function truncated(value: string, max: number): string {
  const chars = [...value]
  return chars.length > max ? `${chars.slice(0, max).join('')}…` : value
}

/**
 * A run of a job, from `GET /api/cron/jobs/{id}/runs`: the run's session row (the shape
 * of `/api/sessions`), or for a script-only job a row for its output document
 * (`source: "cron_output"`, `hermes_cli/web_routers/cron.py:262-280,346-445`).
 */
export interface CronRun {
  id: string
  title?: string
  preview?: string
  /** Unix seconds. */
  startedAt?: number
  lastActive?: number
  endedAt?: number
  source?: string
  /** The job's owning profile, stamped by the dashboard. */
  profile?: string
  messageCount?: number
}

export function parseCronRun(value: unknown): CronRun | undefined {
  const json = asObject(value)
  const id = asString(json?.id)
  if (!json || id === undefined) return undefined
  const run: CronRun = { id }
  const set = <K extends keyof CronRun>(key: K, item: CronRun[K] | undefined) => {
    if (item !== undefined) run[key] = item
  }
  set('title', asString(json.title))
  set('preview', asString(json.preview))
  set('startedAt', asNumber(json.started_at))
  set('lastActive', asNumber(json.last_active))
  set('endedAt', asNumber(json.ended_at))
  set('source', asString(json.source))
  set('profile', asString(json.profile))
  const count = asNumber(json.message_count)
  set('messageCount', count === undefined ? undefined : Math.trunc(count))
  return run
}

/** A script-only run's output document: there is no session to open. */
export function isOutputDocument(run: CronRun): boolean {
  return run.source === 'cron_output' || run.id.startsWith('cron_output:')
}

/** When the run was last active, else when it started (`cron-jobs-section.tsx:504`), in ms. */
export function cronRunTime(run: CronRun): number | undefined {
  const seconds = run.lastActive ?? run.startedAt
  return seconds !== undefined && seconds > 0 ? seconds * 1000 : undefined
}

/**
 * The scheduler names every agent run `cron_{job_id}_{YYYYmmdd_HHMMSS}`
 * (`apps/desktop/src/app/cron/open-cron-run.ts:14-15`).
 */
export function isRunSessionID(id: string | null | undefined): boolean {
  return !!id && /^cron_.+_\d{8}_\d{6}$/.test(id)
}

/** The profile's own Bot Chat. The targets endpoint doesn't list it; Desktop's routine
 * dialog offers it itself (`apps/desktop/src/plugins/hermes-bots/cron.tsx:1033-1040`). */
export const botChatTarget = 'bot-chat'

/**
 * Where a job can deliver, from `GET /api/cron/delivery-targets`: `local` plus the
 * configured gateway platforms (`hermes_cli/web_routers/cron.py:688-711`).
 */
export interface CronDeliveryTarget {
  id: string
  name: string
  /** A platform without a cron home channel is listed with `false`. */
  homeTargetSet: boolean
}

export function parseDeliveryTarget(value: unknown): CronDeliveryTarget | undefined {
  const json = asObject(value)
  const id = asString(json?.id)
  if (!json || id === undefined) return undefined
  return { id, name: asString(json.name) ?? id, homeTargetSet: typeof json.home_target_set === 'boolean' ? json.home_target_set : true }
}

/**
 * The choices for a job: its Bot Chat first, then the server's targets, then any target
 * the job has that neither names (`origin`, `telegram:123`), as written.
 */
export function deliveryOptions(server: readonly CronDeliveryTarget[], deliver: string | undefined): CronDeliveryTarget[] {
  const options: CronDeliveryTarget[] = [{ id: botChatTarget, name: 'Bot Chat', homeTargetSet: true }]
  options.push(...server.filter((target) => target.id !== botChatTarget))
  const known = new Set(options.map((target) => target.id))
  for (const id of parseTargets(deliver)) {
    if (!known.has(id)) options.push({ id, name: id, homeTargetSet: true })
  }
  return options
}

/** A readable name for a target id: Bot Chat, else the server's name for it. */
export function deliveryLabel(id: string, server: readonly CronDeliveryTarget[]): string {
  if (id === botChatTarget) return 'Bot Chat'
  if (id.startsWith(`${botChatTarget}:`)) return `Bot Chat (${id.slice(botChatTarget.length + 1)})`
  const named = server.find((target) => target.id === id)
  if (named) return named.name
  switch (id) {
    case 'local': return 'Local'
    case 'origin': return 'Origin'
    case 'all': return 'All channels'
    default: return id
  }
}

/** An option's name, marked when its platform has no home channel. */
export function deliveryOptionTitle(target: CronDeliveryTarget): string {
  return target.homeTargetSet ? target.name : `${target.name} (no home channel)`
}

/**
 * `datetime.isoformat()` strings, as the job store writes them: with an offset, often
 * with microseconds. Without an offset the server's local time is unknown, so the
 * device's. Milliseconds since the epoch; undefined when unreadable.
 */
export function parseCronDate(value: string | undefined): number | undefined {
  if (!value) return undefined
  let text = value.trim().replace(' ', 'T')
  // Drop fractional seconds: "…:05.123456+00:00" → "…:05+00:00".
  text = text.replace(/(T\d{2}:\d{2}:\d{2})\.\d+/, '$1')
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:?\d{2})?$/.exec(text)
  if (!match) return undefined
  const [, y, mo, d, h, mi, s, zone] = match
  if (!zone) {
    const local = new Date(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s ?? 0))
    return Number.isNaN(local.getTime()) ? undefined : local.getTime()
  }
  const utc = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s ?? 0))
  if (zone === 'Z') return utc
  const sign = zone.startsWith('-') ? -1 : 1
  const digits = zone.slice(1).replace(':', '')
  const offset = (Number(digits.slice(0, 2)) * 60 + Number(digits.slice(2, 4))) * 60 * 1000
  return utc - sign * offset
}
