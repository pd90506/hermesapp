import type { JSONValue } from '../../protocol/jsonrpc.ts'

export type BackgroundProcessState = 'running' | 'done' | 'failed'

/**
 * A process the chat's agent started with `terminal(background=true)`, as the gateway's
 * process registry lists it (`process.list`, `tui_gateway/server.py:2055-2070`, rows from
 * `tools/process_registry.py:2393-2420`) and Desktop's status stack shows it
 * (`toBackgroundItem`, `apps/desktop/src/store/composer-status.ts:299-311`; HermesKit's
 * `BackgroundProcess`).
 */
export interface BackgroundProcess {
  /** The registry's process id (`session_id` in its rows: not a chat's id). */
  id: string
  /** The command's first line, else "background process". */
  title: string
  state: BackgroundProcessState
  exitCode?: number
  /** The newest output, at most 4000 characters. */
  output?: string
}

/** A `process.list` row; undefined without an id. */
export function backgroundProcess(row: JSONValue): BackgroundProcess | undefined {
  if (row === null || typeof row !== 'object' || Array.isArray(row)) return undefined
  const id = row.session_id
  if (typeof id !== 'string' || id === '') return undefined
  const exitCode = typeof row.exit_code === 'number' ? Math.trunc(row.exit_code) : undefined
  const exited = row.status === 'exited'
  const firstLine = (typeof row.command === 'string' ? row.command : '').split('\n')[0]!.trim()
  const output = typeof row.output_tail === 'string' && row.output_tail !== '' ? row.output_tail : undefined
  return {
    id,
    title: firstLine === '' ? 'background process' : firstLine,
    state: exited ? (exitCode !== undefined && exitCode !== 0 ? 'failed' : 'done') : 'running',
    ...(exitCode !== undefined ? { exitCode } : {}),
    ...(output !== undefined ? { output } : {}),
  }
}

/** Desktop's notification body: the title, its exit code, then the output's last three lines (`composer-status.ts:339-350`). */
export function backgroundAlertBody(process: BackgroundProcess): string {
  let body = process.title
  if (process.exitCode !== undefined) body += ` (exit ${process.exitCode})`
  const tail = (process.output ?? '').trim().split('\n').slice(-3)
  if (tail.some((line) => line !== '')) body += '\n' + tail.join('\n')
  return body
}

/** "1 background task" (the Mac's `BackgroundProcessesText`). */
export function backgroundTitle(count: number): string {
  return count === 1 ? '1 background task' : `${count} background tasks`
}

/**
 * The chat's background processes, kept as Desktop keeps them
 * (`reconcileBackgroundProcesses`, `composer-status.ts:318-395`; HermesKit's
 * `BackgroundProcessList`):
 * - rows keep their place; new ones go last;
 * - a finished row goes after a while (4 s, or 12 s when it failed), or at once when the
 *   user stops or dismisses it, and a dismissed one never comes back.
 *
 * Immutable: every change returns a new list.
 */
export class BackgroundProcessList {
  static readonly successLingerMs = 4000
  static readonly failureLingerMs = 12_000
  static readonly empty = new BackgroundProcessList([], new Set())

  private constructor(readonly processes: readonly BackgroundProcess[], private readonly dismissed: ReadonlySet<string>) {}

  get running(): BackgroundProcess[] {
    return this.processes.filter((process) => process.state === 'running')
  }

  /** Takes a `process.list` answer: the new list, and the rows that were running and have now finished, for a notification. */
  reconcile(rows: readonly JSONValue[]): { list: BackgroundProcessList; finished: BackgroundProcess[] } {
    const fresh = new Map<string, BackgroundProcess>()
    const order: string[] = []
    for (const row of rows) {
      const process = backgroundProcess(row)
      if (!process || this.dismissed.has(process.id)) continue
      if (!fresh.has(process.id)) order.push(process.id)
      fresh.set(process.id, process)
    }
    const finished = this.processes.filter((old) => old.state === 'running').flatMap((old) => {
      const now = fresh.get(old.id)
      return now && now.state !== 'running' ? [now] : []
    })
    const next: BackgroundProcess[] = []
    for (const old of this.processes) {
      const now = fresh.get(old.id)
      if (!now) continue
      next.push(now)
      fresh.delete(old.id)
    }
    for (const id of order) {
      const process = fresh.get(id)
      if (process) next.push(process)
    }
    // The registry stops listing ids eventually: forget them then.
    const listed = new Set(rows.flatMap((row) =>
      row !== null && typeof row === 'object' && !Array.isArray(row) && typeof row.session_id === 'string' ? [row.session_id] : []))
    const dismissed = new Set([...this.dismissed].filter((id) => listed.has(id)))
    const same = next.length === this.processes.length &&
      next.every((process, index) => JSON.stringify(process) === JSON.stringify(this.processes[index])) &&
      dismissed.size === this.dismissed.size
    return { list: same ? this : new BackgroundProcessList(next, dismissed), finished }
  }

  /** Drops `id` now, and from every later answer. */
  dismiss(id: string): BackgroundProcessList {
    return new BackgroundProcessList(this.processes.filter((process) => process.id !== id), new Set([...this.dismissed, id]))
  }

  /** How long a finished row stays. */
  static lingerMs(process: BackgroundProcess): number {
    return process.state === 'failed' ? BackgroundProcessList.failureLingerMs : BackgroundProcessList.successLingerMs
  }
}
