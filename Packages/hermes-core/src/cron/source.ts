import { pathSegment, type DashboardAPI } from '../dashboard-api.ts'
import type { JSONValue } from '../protocol/jsonrpc.ts'
import { parseBlueprint, type CronBlueprint } from './blueprint.ts'
import {
  parseCronJob, parseCronJobs, parseCronRun, parseDeliveryTarget, type CronDeliveryTarget, type CronJob, type CronRun,
} from './job.ts'

/**
 * A profile's scheduled jobs on the gateway's dashboard (`hermes_cli/web_routers/cron.py`;
 * HermesKit's `CronSource`). `profile` names the profile whose `cron/jobs.json` is read;
 * per-job calls send it as the owner hint, which the dashboard checks
 * (`_job_owner_profile`, `cron.py:79-97`).
 */
export interface CronSource {
  cronJobs(profile: string): Promise<CronJob[]>
  cronRuns(jobID: string, profile: string, limit: number): Promise<CronRun[]>
  cronDeliveryTargets(profile: string): Promise<CronDeliveryTarget[]>
  pauseCronJob(jobID: string, profile: string): Promise<CronJob>
  resumeCronJob(jobID: string, profile: string): Promise<CronJob>
  /** Runs the job now and answers once the run is recorded, which takes as long as the job. */
  triggerCronJob(jobID: string, profile: string): Promise<CronJob>
  updateCronJob(jobID: string, profile: string, updates: { [key: string]: JSONValue }): Promise<CronJob>
  deleteCronJob(jobID: string, profile: string): Promise<void>
  /** Creates a job from `cronCreateBody`. */
  createCronJob(profile: string, body: { [key: string]: JSONValue }): Promise<CronJob>
  cronBlueprints(profile: string): Promise<CronBlueprint[]>
  /** Fills a blueprint's blanks and creates its job. */
  instantiateCronBlueprint(key: string, values: Record<string, string>, profile: string): Promise<CronJob>
}

/** Trigger waits for the run: Desktop's day-long timeout (`apps/desktop/src/api/cron.ts:19-23`). */
export const cronTriggerTimeoutMs = 24 * 60 * 60 * 1000

function jobOf(answer: unknown): CronJob {
  const job = parseCronJob(answer)
  if (!job) throw new Error('The dashboard sent a job this app could not read.')
  return job
}

function listOf<T>(answer: unknown, key: string, parse: (value: unknown) => T | undefined): T[] {
  const items = answer && typeof answer === 'object' ? (answer as Record<string, unknown>)[key] : undefined
  return Array.isArray(items) ? items.map(parse).filter((item): item is T => item !== undefined) : []
}

/**
 * `CronSource` over the dashboard's REST routes (HermesKit's `DashboardClient` cron calls),
 * with the connection's credential (`GatewayConnection.dashboardAPI`). A refusal is a
 * `DashboardRequestError` with the dashboard's reason.
 */
export class DashboardCronSource implements CronSource {
  constructor(private readonly http: DashboardAPI) {}

  /** A job id as one path segment. Ids are hex, but names are accepted too (`cron.py:79-97`). */
  private job(id: string): string {
    return `/api/cron/jobs/${pathSegment(id)}`
  }

  /** `GET /api/cron/jobs?profile=` (`cron.py:668-670`). */
  async cronJobs(profile: string): Promise<CronJob[]> {
    return parseCronJobs(await this.http.send('GET', '/api/cron/jobs', { query: [['profile', profile]] }))
  }

  /** `GET /api/cron/jobs/{id}/runs?profile=&limit=`: `{runs: [...]}`, newest first (`cron.py:678-680`). */
  async cronRuns(jobID: string, profile: string, limit: number): Promise<CronRun[]> {
    const answer = await this.http.send('GET', `${this.job(jobID)}/runs`, { query: [['profile', profile], ['limit', String(limit)]] })
    return listOf(answer, 'runs', parseCronRun)
  }

  /** `GET /api/cron/delivery-targets?profile=`: `{targets: [...]}` (`cron.py:688-711`). */
  async cronDeliveryTargets(profile: string): Promise<CronDeliveryTarget[]> {
    return listOf(await this.http.send('GET', '/api/cron/delivery-targets', { query: [['profile', profile]] }), 'targets',
      parseDeliveryTarget)
  }

  /** `POST /api/cron/jobs/{id}/{pause|resume|trigger}` (`cron.py:719-731`). */
  private async action(action: 'pause' | 'resume' | 'trigger', jobID: string, profile: string): Promise<CronJob> {
    return jobOf(await this.http.send('POST', `${this.job(jobID)}/${action}`, {
      query: [['profile', profile]],
      ...(action === 'trigger' ? { timeoutMs: cronTriggerTimeoutMs } : {}),
    }))
  }

  pauseCronJob(jobID: string, profile: string): Promise<CronJob> {
    return this.action('pause', jobID, profile)
  }

  resumeCronJob(jobID: string, profile: string): Promise<CronJob> {
    return this.action('resume', jobID, profile)
  }

  triggerCronJob(jobID: string, profile: string): Promise<CronJob> {
    return this.action('trigger', jobID, profile)
  }

  /** `PUT /api/cron/jobs/{id}` with `{updates: {...}}` (`cron.py:714-716`, `CronJobUpdate`). */
  async updateCronJob(jobID: string, profile: string, updates: { [key: string]: JSONValue }): Promise<CronJob> {
    return jobOf(await this.http.send('PUT', this.job(jobID), { query: [['profile', profile]], body: { updates } }))
  }

  /** `DELETE /api/cron/jobs/{id}`: `{ok: true}` (`cron.py:734-736`). */
  async deleteCronJob(jobID: string, profile: string): Promise<void> {
    await this.http.send('DELETE', this.job(jobID), { query: [['profile', profile]] })
  }

  /** `POST /api/cron/jobs?profile=` with a `CronJobCreate` body (`cron.py:716-718`). */
  async createCronJob(profile: string, body: { [key: string]: JSONValue }): Promise<CronJob> {
    return jobOf(await this.http.send('POST', '/api/cron/jobs', { query: [['profile', profile]], body }))
  }

  /** `GET /api/cron/blueprints?profile=`: `{blueprints: [...]}` (`cron.py:891-900`). */
  async cronBlueprints(profile: string): Promise<CronBlueprint[]> {
    return listOf(await this.http.send('GET', '/api/cron/blueprints', { query: [['profile', profile]] }), 'blueprints',
      parseBlueprint)
  }

  /**
   * `POST /api/cron/blueprints/instantiate?profile=` with `{blueprint, values}`; a blank
   * filled in wrong is a 422 with the reason (`cron.py:910-936`).
   */
  async instantiateCronBlueprint(key: string, values: Record<string, string>, profile: string): Promise<CronJob> {
    return jobOf(await this.http.send('POST', '/api/cron/blueprints/instantiate', {
      query: [['profile', profile]], body: { blueprint: key, values },
    }))
  }
}
