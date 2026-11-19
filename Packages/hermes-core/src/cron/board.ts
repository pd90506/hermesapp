import { requestStatus } from '../dashboard-api.ts'
import { describeError } from '../describe.ts'
import { Observable } from '../observable.ts'
import type { CronBlueprint } from './blueprint.ts'
import { cronCreateBody, cronDraftUpdates, type CronJobDraft } from './draft.ts'
import { cronListOrder, type CronDeliveryTarget, type CronJob, type CronRun } from './job.ts'
import { parseCronModelCatalog, type CronModelCatalog } from './models.ts'
import type { CronSource } from './source.ts'

/** The list profile's scheduled jobs, as the Cron Jobs tab shows them. Replaced as a whole on every change. */
export interface CronSnapshot {
  /** The jobs of `profile`, soonest next run first (`cronListOrder`). */
  jobs: readonly CronJob[]
  /** The profile whose jobs `jobs` holds: undefined until its first read comes back. */
  profile?: string
  isLoading: boolean
  error?: string
  /** False when the connection has no REST access, so jobs can't be read. */
  isAvailable: boolean
  /** Recent runs by job id, newest first, for the jobs whose runs were read. */
  runs: Readonly<Record<string, readonly CronRun[]>>
  runErrors: Readonly<Record<string, string>>
  /** The server's delivery targets for `profile` (`local` and configured platforms). */
  targets: readonly CronDeliveryTarget[]
  /** Jobs being run now from the app: the trigger answers when the run ends. */
  triggering: readonly string[]
  /** The ready-made jobs `profile` can start from, once read. */
  blueprints: readonly CronBlueprint[]
}

const empty: CronSnapshot = {
  jobs: [], isLoading: false, isAvailable: true, runs: {}, runErrors: {}, targets: [], triggering: [], blueprints: [],
}

export interface CronBoardOptions {
  /** The profile whose sessions the list shows (the connection's selected profile). */
  listProfile: () => string | undefined
  /** `model.options` for a profile, on the open gateway client. */
  modelOptions?: (profile: string | undefined) => Promise<unknown>
}

export class CronNotConnectedError extends Error {
  constructor() {
    super('Not connected to the gateway.')
  }
}

/**
 * The list profile's scheduled jobs, read and changed through the dashboard's REST routes
 * (`CronSource`). HermesKit's `CronBoard` with `GatewayConnection`'s cron calls.
 */
export class CronBoard extends Observable<CronSnapshot> {
  private source?: CronSource
  private token = 0

  constructor(private readonly options: CronBoardOptions) {
    super(empty)
  }

  private update(change: Partial<CronSnapshot>): void {
    this.set({ ...this.get(), ...change })
  }

  /** The REST routes of the server now connected; undefined when there are none. */
  setSource(source: CronSource | undefined): void {
    if (source === this.source) return
    this.source = source
    this.token += 1
    this.set({ ...empty, isAvailable: source !== undefined })
  }

  /** Drops another profile's jobs, so the tab never shows them under this one's name. */
  private resetIfProfileChanged(profile: string): void {
    const current = this.get().profile
    if (current !== undefined && current !== profile) {
      this.token += 1
      this.set({ ...empty, isAvailable: this.get().isAvailable })
    }
  }

  /** Whether the board holds the list profile's jobs. */
  isCurrent(): boolean {
    const profile = this.get().profile
    return profile !== undefined && profile === this.options.listProfile()
  }

  /** Re-reads the list profile's jobs. */
  async refreshJobs(): Promise<void> {
    const profile = this.options.listProfile()
    if (profile === undefined) return
    this.resetIfProfileChanged(profile)
    const source = this.source
    if (!source) {
      this.update({ isAvailable: false })
      return
    }
    const token = ++this.token
    this.update({ isAvailable: true, isLoading: true })
    try {
      const jobs = await source.cronJobs(profile)
      if (token !== this.token || this.options.listProfile() !== profile) return
      const ids = new Set(jobs.map((job) => job.id))
      const runs = Object.fromEntries(Object.entries(this.get().runs).filter(([id]) => ids.has(id)))
      this.update({ jobs: cronListOrder(jobs), profile, error: undefined, runs, isLoading: false })
    } catch (error) {
      if (token !== this.token || this.options.listProfile() !== profile) return
      this.update({ profile, error: describeError(error), isLoading: false })
    }
  }

  /** Re-reads a job's most recent runs (Desktop's sidebar peek shows 5). */
  async refreshRuns(job: CronJob, limit = 5): Promise<void> {
    const profile = this.get().profile
    const source = this.source
    if (profile === undefined || !source) return
    try {
      const runs = await source.cronRuns(job.id, profile, limit)
      if (this.get().profile !== profile) return
      const { [job.id]: _, ...runErrors } = this.get().runErrors
      this.update({ runs: { ...this.get().runs, [job.id]: runs }, runErrors })
    } catch (error) {
      if (this.get().profile !== profile) return
      this.update({ runErrors: { ...this.get().runErrors, [job.id]: describeError(error) } })
    }
  }

  /** Reads where the list profile's jobs can deliver, once per profile. */
  async loadDeliveryTargets(): Promise<void> {
    const profile = this.get().profile
    const source = this.source
    if (profile === undefined || !source || this.get().targets.length) return
    try {
      const targets = await source.cronDeliveryTargets(profile)
      if (this.get().profile === profile) this.update({ targets })
    } catch {}
  }

  pause(job: CronJob): Promise<void> {
    return this.change((source, profile) => source.pauseCronJob(job.id, profile))
  }

  resume(job: CronJob): Promise<void> {
    return this.change((source, profile) => source.resumeCronJob(job.id, profile))
  }

  /** Sets where the job delivers: a comma list of targets (`toggleDelivery`). */
  setDelivery(job: CronJob, deliver: string): Promise<void> {
    return this.change((source, profile) => source.updateCronJob(job.id, profile, { deliver }))
  }

  /** Runs the job now. Answers when the run is recorded, then re-reads its runs. */
  async trigger(job: CronJob): Promise<void> {
    if (this.get().triggering.includes(job.id)) return
    this.update({ triggering: [...this.get().triggering, job.id] })
    try {
      try {
        await this.change((source, profile) => source.triggerCronJob(job.id, profile))
      } catch (error) {
        // A one-shot can remove itself once it ran (`cron.py:640-650`).
        if (requestStatus(error) === 404) {
          await this.refreshJobs()
          return
        }
        throw error
      }
    } finally {
      this.update({ triggering: this.get().triggering.filter((id) => id !== job.id) })
    }
    await this.refreshRuns(job)
  }

  async delete(job: CronJob): Promise<void> {
    const { source, profile } = this.require()
    await source.deleteCronJob(job.id, profile)
    if (this.get().profile !== profile) return
    const { [job.id]: _, ...runs } = this.get().runs
    this.update({ jobs: this.get().jobs.filter((item) => item.id !== job.id), runs })
  }

  /**
   * Creates a job in the list profile, then re-reads the list (Desktop's
   * `mutateAndRefreshCronJobs`, `apps/desktop/src/app/cron/cron-actions.ts`).
   */
  async create(draft: CronJobDraft): Promise<CronJob> {
    const { source, profile } = this.require()
    const job = await source.createCronJob(profile, cronCreateBody(draft))
    await this.refreshJobs()
    return job
  }

  /** Saves the editor's changes to a job. */
  save(job: CronJob, draft: CronJobDraft): Promise<void> {
    return this.change((source, profile) => source.updateCronJob(job.id, profile, cronDraftUpdates(draft)))
  }

  /** Reads the list profile's blueprints, once per profile. A server without them has none. */
  async loadBlueprints(): Promise<void> {
    const profile = this.get().profile
    const source = this.source
    if (profile === undefined || !source || this.get().blueprints.length) return
    try {
      const blueprints = await source.cronBlueprints(profile)
      if (this.get().profile === profile) this.update({ blueprints })
    } catch {}
  }

  /** Fills in a blueprint and creates its job in the list profile. */
  async createFromBlueprint(blueprint: CronBlueprint, values: Record<string, string>): Promise<CronJob> {
    const { source, profile } = this.require()
    const job = await source.instantiateCronBlueprint(blueprint.key, values, profile)
    await this.refreshJobs()
    return job
  }

  /**
   * The models a job can pin: the list profile's `model.options`, as the chat's model
   * picker offers them (`CronEditorDialog`'s `requestModelOptions`, `index.tsx:1258-1266`).
   */
  async modelCatalog(): Promise<CronModelCatalog> {
    const call = this.options.modelOptions
    if (!call) throw new CronNotConnectedError()
    return parseCronModelCatalog(await call(this.get().profile ?? this.options.listProfile()))
  }

  private require(): { source: CronSource; profile: string } {
    const profile = this.get().profile
    const source = this.source
    if (profile === undefined || !source) throw new CronNotConnectedError()
    return { source, profile }
  }

  private async change(call: (source: CronSource, profile: string) => Promise<CronJob>): Promise<void> {
    const { source, profile } = this.require()
    const updated = await call(source, profile)
    if (this.get().profile !== profile) return
    const jobs = this.get().jobs.map((job) => job.id === updated.id ? updated : job)
    this.update({ jobs: cronListOrder(jobs) })
  }
}
