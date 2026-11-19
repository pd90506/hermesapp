import { GatewayClientError, type GatewayClient, type GatewayEvent } from '../../client.ts'
import { Observable } from '../../observable.ts'
import type { JSONValue } from '../../protocol/jsonrpc.ts'
import { eventKind } from '../types.ts'
import { BackgroundProcessList, type BackgroundProcess } from './background-processes.ts'
import { SubagentRoster } from './subagents.ts'

/** The gateway methods this module calls (`tui_gateway/methods_subagents.py`, `methods_tools.py`). */
export const BackgroundMethod = {
  subagentList: 'subagent.list',
  subagentSteer: 'subagent.steer',
  subagentInterrupt: 'subagent.interrupt',
  processList: 'process.list',
  processKill: 'process.kill',
} as const

/** What a chat's pills paint from. Replaced whole on every change. */
export interface ChatActivityView {
  subagents: SubagentRoster
  processes: BackgroundProcessList
}

/** What the activity needs from its chat (`ChatSession`). */
export interface ChatActivityHost {
  readonly client: GatewayClient | undefined
  readonly sessionID: string
  readonly isRuntimeGone: boolean
  readonly isRunning: boolean
  /** A process that was running has finished: a notification (package J's alerts). */
  processFinished(process: BackgroundProcess): void
}

/**
 * A chat's work beside its transcript (package J): the subagents its turns delegated to
 * and the processes its agent left running in the background, as HermesKit's
 * `ChatSession.subagents` / `backgroundProcesses` keep them. Fed by the chat's events,
 * reconciled with `subagent.list` and `process.list` when the chat shows (`watch`) and
 * every 5 s after, as Desktop polls (`BACKGROUND_POLL_MS`).
 */
export class ChatActivity extends Observable<ChatActivityView> {
  static readonly pollIntervalMs = 5000

  private readonly dismissals = new Map<string, ReturnType<typeof setTimeout>>()
  private watchers = 0
  private pollTimer?: ReturnType<typeof setInterval>
  private detached = false

  constructor(private readonly host: ChatActivityHost) {
    super({ subagents: SubagentRoster.empty, processes: BackgroundProcessList.empty })
  }

  private update(change: Partial<ChatActivityView>): void {
    const next = { ...this.get(), ...change }
    if (next.subagents === this.get().subagents && next.processes === this.get().processes) return
    this.set(next)
  }

  // MARK: Events

  /** Takes one of the chat's events. Answers whether it was a `subagent.*` one (the transcript skips those). */
  apply(event: GatewayEvent): boolean {
    if (event.type.startsWith('subagent.')) {
      this.update({ subagents: this.get().subagents.apply(event) })
      return true
    }
    const kind = eventKind(event)
    switch (kind.kind) {
      case 'messageStart':
        // A new turn: the last one's finished children go (`pruneFinishedSessionSubagents`).
        this.update({ subagents: this.get().subagents.pruneFinished() })
        break
      case 'statusUpdate':
        // The gateway's poller announces a process finishing (`gateway-event/status.ts:116-119`).
        if (kind.update.kind === 'process') void this.refreshBackgroundProcesses()
        break
      case 'toolComplete':
        // Only these start or reap background processes (`gateway-event/tools.ts:191-197`).
        if (kind.complete.name === 'terminal' || kind.complete.name === 'process') void this.refreshBackgroundProcesses()
        break
      default:
        break
    }
    return false
  }

  /** The turn was stopped, which stops its children too (Desktop's `clearSessionSubagents`). */
  turnStopped(): void {
    this.update({ subagents: this.get().subagents.clear() })
  }

  // MARK: Watching

  /**
   * The chat is on screen: reads both rosters now, then every 5 s the subagents while a
   * turn runs or a child does, and the processes while one runs. Returns the stop.
   */
  watch(): () => void {
    this.watchers += 1
    if (this.watchers === 1) {
      void this.refreshSubagents()
      void this.refreshBackgroundProcesses()
      this.pollTimer = setInterval(() => this.poll(), ChatActivity.pollIntervalMs)
    }
    let stopped = false
    return () => {
      if (stopped) return
      stopped = true
      this.watchers -= 1
      if (this.watchers === 0) this.stopPolling()
    }
  }

  private poll(): void {
    const view = this.get()
    if (this.host.isRunning || view.subagents.live.length > 0) void this.refreshSubagents()
    if (view.processes.running.length > 0) void this.refreshBackgroundProcesses()
  }

  private stopPolling(): void {
    if (this.pollTimer !== undefined) clearInterval(this.pollTimer)
    this.pollTimer = undefined
  }

  /** The chat left its connection: no more reads or timers. */
  detach(): void {
    this.detached = true
    this.stopPolling()
    for (const timer of this.dismissals.values()) clearTimeout(timer)
    this.dismissals.clear()
  }

  // MARK: Subagents

  /** Reconciles the subagents with `subagent.list`. A failure (an older gateway, a reclaimed runtime) changes nothing. */
  async refreshSubagents(): Promise<void> {
    const client = this.readyClient()
    if (!client) return
    const id = this.host.sessionID
    let answer: JSONValue
    try { answer = await client.call(BackgroundMethod.subagentList, { session_id: id }) } catch { return }
    const rows = field(answer, 'subagents')
    if (!Array.isArray(rows) || id !== this.host.sessionID || this.detached) return
    this.update({ subagents: this.get().subagents.reconcile(rows) })
  }

  /**
   * Queues guidance for a running subagent, which it reads with its next tool result
   * (`subagent.steer`). False: the gateway refused it (the child ended, or isn't this chat's).
   */
  async steerSubagent(subagentID: string, text: string): Promise<boolean> {
    const trimmed = text.trim()
    if (trimmed === '') return false
    const answer = await this.requireClient().call(BackgroundMethod.subagentSteer, {
      session_id: this.host.sessionID, subagent_id: subagentID, text: trimmed,
    })
    return field(answer, 'status') === 'queued'
  }

  /** Stops a subagent (`subagent.interrupt`). False: no such child was running. Its `subagent.complete` then marks it interrupted. */
  async stopSubagent(subagentID: string): Promise<boolean> {
    const answer = await this.requireClient().call(BackgroundMethod.subagentInterrupt, {
      session_id: this.host.sessionID, subagent_id: subagentID,
    })
    return field(answer, 'found') === true
  }

  // MARK: Background processes

  /**
   * Reconciles the background processes with `process.list`. A process that finished
   * since the last read raises a notification; a finished row goes by itself after a
   * while. A failure changes nothing.
   */
  async refreshBackgroundProcesses(): Promise<void> {
    const client = this.readyClient()
    if (!client) return
    const id = this.host.sessionID
    let answer: JSONValue
    try { answer = await client.call(BackgroundMethod.processList, { session_id: id }) } catch { return }
    const rows = field(answer, 'processes')
    if (!Array.isArray(rows) || id !== this.host.sessionID || this.detached) return
    const { list, finished } = this.get().processes.reconcile(rows)
    this.update({ processes: list })
    for (const process of list.processes) {
      if (process.state === 'running' || this.dismissals.has(process.id)) continue
      this.dismissals.set(process.id, setTimeout(() => this.dismissBackgroundProcess(process.id), BackgroundProcessList.lingerMs(process)))
    }
    for (const process of finished) this.host.processFinished(process)
  }

  /** Drops a finished process's row now. */
  dismissBackgroundProcess(id: string): void {
    const timer = this.dismissals.get(id)
    if (timer !== undefined) clearTimeout(timer)
    this.dismissals.delete(id)
    this.update({ processes: this.get().processes.dismiss(id) })
  }

  /** Kills one background process (`process.kill`), then drops its row. On a failure the row stays, to try again. */
  async stopBackgroundProcess(id: string): Promise<void> {
    await this.requireClient().call(BackgroundMethod.processKill, { session_id: this.host.sessionID, process_id: id })
    this.dismissBackgroundProcess(id)
  }

  // MARK: Clients

  private readyClient(): GatewayClient | undefined {
    if (this.detached || this.host.isRuntimeGone) return undefined
    return this.host.client
  }

  private requireClient(): GatewayClient {
    const client = this.readyClient()
    if (!client) throw new GatewayClientError('notConnected')
    return client
  }
}

function field(value: JSONValue, key: string): JSONValue | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value[key] : undefined
}
