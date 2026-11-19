import type { GatewayEvent } from '../../client.ts'
import type { JSONValue } from '../../protocol/jsonrpc.ts'

/**
 * A child agent the chat's turn delegated work to (`delegate_task`), as Desktop's status
 * stack shows it above the composer (`apps/desktop/src/store/subagents.ts`; HermesKit's
 * `SubagentRun`).
 */
export type SubagentStatus = 'queued' | 'running' | 'completed' | 'failed' | 'interrupted'

export type SubagentActivityKind = 'tool' | 'progress' | 'thinking' | 'summary'

/** A line of what the child did: a tool call, a progress note, its thinking, or its final summary. */
export interface SubagentActivity {
  kind: SubagentActivityKind
  text: string
  isError: boolean
}

export interface SubagentRun {
  /** `subagent_id`, else Desktop's fallback key from the parent, index and goal. */
  id: string
  parentID?: string
  goal: string
  model?: string
  status: SubagentStatus
  /** Its place in a batch of children spawned together (`delegation_id`). */
  delegationID?: string
  taskIndex: number
  taskCount: number
  /** Unix milliseconds. */
  startedAt: number
  updatedAt: number
  durationSeconds?: number
  toolCount?: number
  /** The tool it is running, while it runs. */
  currentTool?: string
  /** The newest lines, oldest first, at most `SubagentRoster.activityLimit`. */
  activity: readonly SubagentActivity[]
  summary?: string
  /** The child's own stored session id. */
  childSessionID?: string
}

export const isLiveSubagent = (run: SubagentRun): boolean => run.status === 'queued' || run.status === 'running'

/**
 * Desktop's `asStatus`: timeouts and errors failed, cancellations interrupted. A
 * `subagent.complete` is terminal, so an unknown or live status there failed; a live
 * event's unknown status is running.
 */
export function subagentStatus(value: string | undefined, terminal: boolean): SubagentStatus {
  switch (value) {
    case 'completed': return 'completed'
    case 'failed': case 'timeout': case 'error': return 'failed'
    case 'interrupted': case 'cancelled': case 'canceled': return 'interrupted'
    case 'queued': if (!terminal) return 'queued'
  }
  return terminal ? 'failed' : 'running'
}

type Payload = Record<string, JSONValue | undefined>

/**
 * The chat's subagents (HermesKit's `SubagentRoster`): fed by the `subagent.*` events
 * of its runtime session (`tui_gateway/tool_progress.py:457-499`) and reconciled with
 * `subagent.list` (`tui_gateway/methods_subagents.py:53-63`), as Desktop's store does.
 *
 * - Only `subagent.spawn_requested` and `subagent.start` add a row; other events update
 *   one already there.
 * - A finished row keeps its status: later events and snapshots never revive it.
 * - The next prompt (`message.start`) drops the finished rows; running children outlive
 *   the turn that spawned them.
 *
 * Immutable: every change returns a new roster, so a view can compare by identity.
 */
export class SubagentRoster {
  static readonly activityLimit = 24
  static readonly previewLimit = 220
  static readonly toolPreviewLimit = 96
  static readonly empty = new SubagentRoster([], new Set())

  private constructor(
    readonly runs: readonly SubagentRun[],
    /** Finished rows already dropped, which a late event or snapshot must not bring back. */
    private readonly retired: ReadonlySet<string>,
  ) {}

  /** The children still queued or running, the oldest first. */
  get live(): SubagentRun[] {
    return this.runs.filter(isLiveSubagent)
      .sort((a, b) => a.startedAt - b.startedAt || a.taskIndex - b.taskIndex)
  }

  /** Applies a `subagent.*` event; the same roster when nothing changed. */
  apply(event: GatewayEvent, now = Date.now()): SubagentRoster {
    if (!event.type.startsWith('subagent.')) return this
    const payload = asPayload(event.payload)
    const id = SubagentRoster.id(payload)
    if (this.retired.has(id)) return this
    const index = this.runs.findIndex((run) => run.id === id)
    if (index >= 0) {
      const previous = this.runs[index]!
      if (!isLiveSubagent(previous)) return this
      const runs = this.runs.slice()
      runs[index] = project(payload, previous, event.type, now)
      return new SubagentRoster(runs, this.retired)
    }
    if (event.type === 'subagent.spawn_requested' || event.type === 'subagent.start') {
      return new SubagentRoster([...this.runs, project(payload, undefined, event.type, now)], this.retired)
    }
    return this
  }

  /** Drops the finished rows (Desktop's `pruneFinishedSessionSubagents`). */
  pruneFinished(): SubagentRoster {
    const finished = this.runs.filter((run) => !isLiveSubagent(run))
    if (finished.length === 0) return this
    return new SubagentRoster(this.runs.filter(isLiveSubagent), new Set([...this.retired, ...finished.map((run) => run.id)]))
  }

  /** Drops every row: the turn was stopped, which stops its children. */
  clear(): SubagentRoster {
    if (this.runs.length === 0) return this
    return new SubagentRoster([], new Set([...this.retired, ...this.runs.map((run) => run.id)]))
  }

  /**
   * Reconciles a `subagent.list` answer: live rows it no longer lists are gone, rows it
   * lists are added or updated, finished rows stay. The activity already shown stays; a
   * row with none yet shows the last tool the roster names.
   */
  reconcile(snapshot: readonly JSONValue[], now = Date.now()): SubagentRoster {
    const payloads = snapshot.map(asPayload)
    const ids = new Set(payloads.map((payload) => text(payload.subagent_id)).filter((id): id is string => id !== undefined))
    const runs = this.runs.filter((run) => !isLiveSubagent(run) || ids.has(run.id))
    for (const payload of payloads) {
      const id = text(payload.subagent_id)
      if (id === undefined || this.retired.has(id)) continue
      const index = runs.findIndex((run) => run.id === id)
      const previous = index >= 0 ? runs[index] : undefined
      if (previous && !isLiveSubagent(previous)) continue
      let run = project(payload, previous, '', now)
      const started = num(payload.started_at)
      if (started !== undefined && started > 0) run = { ...run, startedAt: started * 1000 }
      run = { ...run, updatedAt: previous?.updatedAt ?? run.startedAt }
      const tool = text(payload.last_tool)
      if (run.activity.length === 0 && tool !== undefined) {
        run = { ...run, activity: [{ kind: 'tool', text: toolText(tool, ''), isError: false }] }
      }
      if (index >= 0) runs[index] = run
      else runs.push(run)
    }
    if (runs.length === this.runs.length && runs.every((run, index) => sameRun(run, this.runs[index]!))) return this
    return new SubagentRoster(runs, this.retired)
  }

  /** `subagent_id`, else Desktop's fallback key. */
  static id(payload: Payload): string {
    const id = text(payload.subagent_id)
    if (id !== undefined) return id
    const parent = text(payload.parent_id) ?? 'root'
    return `${parent}:${int(payload.task_index) ?? 0}:${str(payload.goal) ?? ''}`
  }
}

// MARK: Projection (Desktop's `toProgress`)

function project(payload: Payload, previous: SubagentRun | undefined, eventType: string, now: number): SubagentRun {
  const status = subagentStatus(text(payload.status), eventType === 'subagent.complete')
  const duration = num(payload.duration_seconds)
  const timeout = text(payload.status) === 'timeout'
    ? `Timed out after ${duration !== undefined ? duration.toFixed(0) : '?'}s`
    : undefined
  const activity = [...(previous?.activity ?? [])]
  for (const line of lines(payload, status, eventType, timeout)) {
    const last = activity.at(-1)
    if (last && last.kind === line.kind && last.text === line.text && last.isError === line.isError) continue
    activity.push(line)
  }
  if (activity.length > SubagentRoster.activityLimit) activity.splice(0, activity.length - SubagentRoster.activityLimit)
  const live = status === 'queued' || status === 'running'
  const run: SubagentRun = {
    id: previous?.id ?? SubagentRoster.id(payload),
    goal: text(payload.goal) ?? previous?.goal ?? 'Subagent',
    status,
    taskIndex: int(payload.task_index) ?? previous?.taskIndex ?? 0,
    taskCount: int(payload.task_count) ?? previous?.taskCount ?? 1,
    startedAt: previous?.startedAt ?? now,
    updatedAt: now,
    activity,
  }
  const optional: Partial<SubagentRun> = {
    parentID: text(payload.parent_id) ?? previous?.parentID,
    model: text(payload.model) ?? previous?.model,
    delegationID: text(payload.delegation_id) ?? previous?.delegationID,
    durationSeconds: duration ?? previous?.durationSeconds,
    toolCount: int(payload.tool_count) ?? previous?.toolCount,
    currentTool: live ? (text(payload.tool_name) ?? previous?.currentTool) : undefined,
    summary: text(payload.summary) ?? timeout ?? previous?.summary,
    childSessionID: text(payload.child_session_id) ?? previous?.childSessionID,
  }
  for (const [key, value] of Object.entries(optional)) {
    if (value !== undefined) (run as unknown as Record<string, unknown>)[key] = value
  }
  return run
}

function lines(payload: Payload, status: SubagentStatus, eventType: string, timeout: string | undefined): SubagentActivity[] {
  const out: SubagentActivity[] = []
  const error = payload.error
  const isError = error !== undefined && error !== null && error !== false
  const tool = str(payload.tool_name) ?? ''
  const preview = text(payload.tool_preview) ?? str(payload.text) ?? ''
  const line = compact(text(payload.text) ?? preview)
  const tails = Array.isArray(payload.output_tail) ? payload.output_tail : []
  for (const tail of tails.map(asPayload)) {
    const tailTool = str(tail.tool) ?? ''
    const tailPreview = str(tail.preview) ?? ''
    const shown = tailTool === '' ? compact(tailPreview) : toolText(tailTool, tailPreview)
    if (shown !== '') out.push({ kind: tailTool === '' ? 'progress' : 'tool', text: shown, isError: tail.is_error === true })
  }
  if (tool !== '') out.push({ kind: 'tool', text: toolText(tool, preview), isError })
  if (eventType === 'subagent.progress' && line !== '') out.push({ kind: 'progress', text: line, isError })
  if (eventType === 'subagent.thinking' && line !== '') out.push({ kind: 'thinking', text: line, isError: false })
  const summary = compact(text(payload.summary) ?? text(payload.text) ?? timeout ?? '')
  if (status !== 'queued' && status !== 'running' && summary !== '') {
    out.push({ kind: 'summary', text: summary, isError: status === 'failed' })
  }
  return out
}

/** One line, at most `limit` characters. */
export function compact(value: string, limit = SubagentRoster.previewLimit): string {
  const line = value.split(/\s+/).filter((part) => part !== '').join(' ')
  const characters = [...line]
  return characters.length > limit ? characters.slice(0, limit - 1).join('') + '…' : line
}

/** `web_search` with its preview as `Web Search("…")`, as Desktop's `formatTool`. */
export function toolText(name: string, preview: string): string {
  const label = name.split('_').filter((part) => part !== '').map((part) => part[0]!.toUpperCase() + part.slice(1)).join(' ')
  const snippet = compact(preview, SubagentRoster.toolPreviewLimit)
  const shown = label === '' ? name : label
  return snippet === '' ? shown : `${shown}("${snippet}")`
}

function sameRun(a: SubagentRun, b: SubagentRun): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}

function asPayload(value: JSONValue | undefined): Payload {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Payload : {}
}

function str(value: JSONValue | undefined): string | undefined {
  return typeof value === 'string' ? value : undefined
}

/** A string that is not empty. */
function text(value: JSONValue | undefined): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

function num(value: JSONValue | undefined): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function int(value: JSONValue | undefined): number | undefined {
  const number = num(value)
  return number !== undefined ? Math.trunc(number) : undefined
}
