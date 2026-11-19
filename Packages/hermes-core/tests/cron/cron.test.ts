import { describe, expect, test } from 'vitest'
import {
  CronBoard, DashboardCronSource, DashboardRequestError, cronJobTitle, blueprintInitialValues, cronCreateBody, cronDraftFrom, cronDraftProblem, cronJob,
  cronListOrder, cronTriggerTimeoutMs, deliveryLabel, deliveryOptions, isOutputDocument, newCronDraft, overdueSince,
  parseBlueprint, parseCronJobs, parseCronRun, parseCronSchedule, parseDeliveryTarget, scheduleSummary, cronDraftUpdates,
  type CronJob, type DashboardAPI, type CronSource, type JSONValue,
} from '../../src/index.ts'

describe('jobs', () => {
  test('rows that are not jobs are dropped, not the list', () => {
    expect(parseCronJobs([{ name: 'no id' }, 'x', null, { id: 'a' }]).map((job) => job.id)).toEqual(['a'])
    expect(parseCronJobs({ jobs: [] })).toEqual([])
  })

  test('titles fall back like Desktop', () => {
    expect(cronJobTitle(cronJob({ id: 'j', prompt: 'a'.repeat(70) }))).toBe(`${'a'.repeat(60)}…`)
    expect(cronJobTitle(cronJob({ id: 'j', script: 'check.sh' }))).toBe('check.sh')
    expect(cronJobTitle(cronJob({ id: 'j' }))).toBe('j')
  })

  test('soonest next run first, none last, then by title', () => {
    const now = Date.now()
    const jobs = [
      cronJob({ id: 'none-b', name: 'b' }),
      cronJob({ id: 'later', nextRunAt: now + 3_600_000 }),
      cronJob({ id: 'none-a', name: 'a' }),
      cronJob({ id: 'soon', nextRunAt: now + 60_000 }),
    ]
    expect(cronListOrder(jobs).map((job) => job.id)).toEqual(['soon', 'later', 'none-a', 'none-b'])
  })

  test('overdue: more than 15 minutes past, unless not expected to fire', () => {
    const now = Date.now()
    const stale = now - 20 * 60_000
    expect(overdueSince(cronJob({ id: 'j', nextRunAt: stale }), now)).toBe(stale)
    expect(overdueSince(cronJob({ id: 'j', nextRunAt: now - 5 * 60_000 }), now)).toBeUndefined()
    expect(overdueSince(cronJob({ id: 'j', state: 'paused', nextRunAt: stale }), now)).toBeUndefined()
  })

  test('runs: a session row and an output document (cron.py:262-280,397)', () => {
    const session = parseCronRun({ id: 'cron_a1_20261019_090004', source: 'cron', started_at: 1760878804.5,
      last_active: 1760878860.0, message_count: 4, profile: 'coder' })!
    const output = parseCronRun({ id: 'cron_output:a1:2026-10-18_09-00-03', source: 'cron_output', preview: 'disk 41%' })!
    expect(isOutputDocument(session)).toBe(false)
    expect(isOutputDocument(output)).toBe(true)
    expect(session.profile).toBe('coder')
    expect(parseCronRun({ title: 'no id' })).toBeUndefined()
  })

  test('delivery options and labels', () => {
    const server = [
      parseDeliveryTarget({ id: 'local', name: 'Local (save only)', home_target_set: true })!,
      parseDeliveryTarget({ id: 'telegram', name: 'Telegram', home_target_set: false })!,
    ]
    expect(server[1]!.homeTargetSet).toBe(false)
    expect(deliveryOptions(server, 'origin,local').map((target) => target.id)).toEqual(['bot-chat', 'local', 'telegram', 'origin'])
    expect(deliveryLabel('local', server)).toBe('Local (save only)')
    expect(deliveryLabel('bot-chat', server)).toBe('Bot Chat')
    expect(deliveryLabel('bot-chat:research', server)).toBe('Bot Chat (research)')
  })
})

describe('schedules and drafts', () => {
  test('summaries', () => {
    expect(scheduleSummary(parseCronSchedule('0 9 * * *'), 'en-US')).toBe('Every day at 9:00 AM')
    expect(scheduleSummary(parseCronSchedule('30 7 * * 1'), 'en-US')).toBe('Every Monday at 7:30 AM')
    expect(scheduleSummary(parseCronSchedule('5 * * * *'), 'en-US')).toBe('Every hour at :05')
    expect(scheduleSummary(parseCronSchedule('0 * * * *'), 'en-US')).toBe('Every hour, on the hour')
    expect(scheduleSummary(parseCronSchedule('every 2h'), 'en-US')).toBeUndefined()
  })

  test('validation (validateCronEditor)', () => {
    const draft = newCronDraft()
    expect(cronDraftProblem(draft)).toBe('prompt')
    expect(cronDraftProblem({ ...draft, schedule: { ...draft.schedule, frequency: 'custom', custom: ' ' } }))
      .toBe('promptAndSchedule')
    expect(cronDraftProblem({ ...draft, prompt: 'go' })).toBeUndefined()
    const script = cronDraftFrom(cronJob({ id: 's', script: 'x.sh', noAgent: true, scheduleDisplay: 'every 2h' }))
    expect(cronDraftProblem(script)).toBeUndefined()
  })

  test('create body: a model only when picked', () => {
    expect(cronCreateBody({ ...newCronDraft(), prompt: ' Brief ', name: ' ' }))
      .toEqual({ prompt: 'Brief', schedule: '0 9 * * *', deliver: 'local' })
    expect(cronCreateBody({ ...newCronDraft(), prompt: 'p', name: 'N', model: { provider: 'anthropic', model: 'm' } }))
      .toEqual({ prompt: 'p', schedule: '0 9 * * *', deliver: 'local', name: 'N', model: 'm', provider: 'anthropic' })
  })

  test('updates: agent jobs always send both model fields; script jobs neither', () => {
    const agent = cronDraftFrom(cronJob({ id: 'a', prompt: 'p', model: 'm', provider: 'x', scheduleDisplay: '0 9 * * *' }))
    expect(cronDraftUpdates({ ...agent, model: undefined }))
      .toEqual({ deliver: 'local', name: '', schedule: '0 9 * * *', prompt: 'p', model: null, provider: null })
    const script = cronDraftFrom(cronJob({ id: 's', script: 'x.sh', noAgent: true, scheduleDisplay: 'every 2h' }))
    expect(cronDraftUpdates(script)).toEqual({ deliver: 'local', name: '', schedule: 'every 2h' })
  })

  test('blueprints: unknown kinds are text, origin delivery starts local', () => {
    const blueprint = parseBlueprint({ key: 'news', title: 'News', fields: [
      { name: 'topic', type: 'text', label: 'Topic', default: 'AI' },
      { name: 'when', type: 'clock' },
      { name: 'deliver', type: 'enum', default: 'origin', options: ['origin', 'local'] },
    ] })!
    expect(blueprint.fields.map((field) => field.kind)).toEqual(['text', 'text', 'enum'])
    expect(blueprintInitialValues(blueprint)).toEqual({ topic: 'AI', when: '', deliver: 'local' })
  })
})

const storedJob = { id: 'a1', name: 'Brief', deliver: 'bot-chat,telegram', enabled: true }

class FakeHTTP implements DashboardAPI {
  readonly requests: Array<{ method: string; path: string; query?: ReadonlyArray<readonly [string, string]>; body?: JSONValue; timeoutMs?: number }> = []
  constructor(private readonly answers: unknown[]) {}
  async send(method: string, path: string,
    options: { query?: ReadonlyArray<readonly [string, string]>; body?: JSONValue; timeoutMs?: number } = {}): Promise<JSONValue> {
    this.requests.push({ method, path, ...options })
    const answer = this.answers.shift()
    if (answer instanceof Error) throw answer
    return answer as JSONValue
  }
}

describe('DashboardCronSource', () => {
  test('lists, reads runs and targets with the profile', async () => {
    const http = new FakeHTTP([[storedJob], { runs: [{ id: 'cron_a1_20261019_090004' }] }, { targets: [{ id: 'local' }] }])
    const source = new DashboardCronSource(http)
    expect((await source.cronJobs('coder')).map((job) => job.id)).toEqual(['a1'])
    expect(await source.cronRuns('a1', 'coder', 5)).toHaveLength(1)
    expect((await source.cronDeliveryTargets('coder')).map((target) => target.id)).toEqual(['local'])
    expect(http.requests.map(({ method, path, query }) => [method, path, query])).toEqual([
      ['GET', '/api/cron/jobs', [['profile', 'coder']]],
      ['GET', '/api/cron/jobs/a1/runs', [['profile', 'coder'], ['limit', '5']]],
      ['GET', '/api/cron/delivery-targets', [['profile', 'coder']]],
    ])
  })

  test('actions, updates and the trigger that waits', async () => {
    const http = new FakeHTTP([storedJob, storedJob, storedJob, storedJob, { ok: true }, storedJob, storedJob])
    const source = new DashboardCronSource(http)
    await source.pauseCronJob('a 1', 'coder')
    await source.resumeCronJob('a1', 'coder')
    await source.triggerCronJob('a1', 'coder')
    await source.updateCronJob('a1', 'coder', { deliver: 'bot-chat' })
    await source.deleteCronJob('a1', 'coder')
    await source.createCronJob('coder', { prompt: 'p', schedule: '0 9 * * *', deliver: 'local' })
    await source.instantiateCronBlueprint('news', { topic: 'AI' }, 'coder')
    expect(http.requests.map(({ method, path }) => `${method} ${path}`)).toEqual([
      'POST /api/cron/jobs/a%201/pause', 'POST /api/cron/jobs/a1/resume', 'POST /api/cron/jobs/a1/trigger',
      'PUT /api/cron/jobs/a1', 'DELETE /api/cron/jobs/a1', 'POST /api/cron/jobs', 'POST /api/cron/blueprints/instantiate',
    ])
    expect(http.requests[0]!.timeoutMs).toBeUndefined()
    expect(http.requests[2]!.timeoutMs).toBe(cronTriggerTimeoutMs)
    expect(http.requests[3]!.body).toEqual({ updates: { deliver: 'bot-chat' } })
    expect(http.requests[6]!.body).toEqual({ blueprint: 'news', values: { topic: 'AI' } })
  })
})

/** Scripted jobs per profile, recording every call (HermesKit's `FakeCronSource`). */
class FakeCronSource implements CronSource {
  readonly calls: string[] = []
  readonly updates: Array<{ [key: string]: JSONValue }> = []
  triggerError?: Error
  constructor(private readonly jobs: Record<string, CronJob[]>) {}

  private change(id: string, profile: string, edit: (job: CronJob) => CronJob): CronJob {
    const list = this.jobs[profile] ?? []
    const index = list.findIndex((job) => job.id === id)
    if (index < 0) throw new DashboardRequestError(404, 'Job not found')
    list[index] = edit(list[index]!)
    return list[index]!
  }

  async cronJobs(profile: string) { this.calls.push(`list ${profile}`); return [...(this.jobs[profile] ?? [])] }
  async cronRuns(jobID: string, profile: string) {
    this.calls.push(`runs ${jobID}`)
    return [{ id: `cron_${jobID}_20261019_090004`, profile }]
  }
  async cronDeliveryTargets() { return [{ id: 'local', name: 'Local (save only)', homeTargetSet: true }] }
  async pauseCronJob(id: string, profile: string) {
    this.calls.push(`pause ${id}`)
    return this.change(id, profile, (job) => ({ ...job, state: 'paused', enabled: false }))
  }
  async resumeCronJob(id: string, profile: string) {
    this.calls.push(`resume ${id}`)
    return this.change(id, profile, (job) => ({ ...job, state: 'scheduled', enabled: true }))
  }
  async triggerCronJob(id: string, profile: string) {
    this.calls.push(`trigger ${id}`)
    if (this.triggerError) throw this.triggerError
    return this.change(id, profile, (job) => ({ ...job, lastStatus: 'ok' }))
  }
  async updateCronJob(id: string, profile: string, updates: { [key: string]: JSONValue }) {
    this.calls.push(`update ${id}`)
    this.updates.push(updates)
    return this.change(id, profile, (job) => ({ ...job, deliver: String(updates.deliver) }))
  }
  async deleteCronJob(id: string, profile: string) {
    this.calls.push(`delete ${id}`)
    this.jobs[profile] = (this.jobs[profile] ?? []).filter((job) => job.id !== id)
  }
  async createCronJob(profile: string, body: { [key: string]: JSONValue }) {
    this.calls.push(`create ${profile}`)
    const job = cronJob({ id: 'new', prompt: String(body.prompt) })
    ;(this.jobs[profile] ??= []).push(job)
    return job
  }
  async cronBlueprints() { return [] }
  async instantiateCronBlueprint(key: string) { return cronJob({ id: `bp-${key}` }) }
}

describe('CronBoard', () => {
  test('reads the list profile’s jobs, never another profile’s under its name', async () => {
    let profile = 'coder'
    const source = new FakeCronSource({
      coder: [cronJob({ id: 'b', nextRunAt: Date.now() + 7_200_000 }), cronJob({ id: 'a', nextRunAt: Date.now() + 60_000 })],
      default: [cronJob({ id: 'd' })],
    })
    const board = new CronBoard({ listProfile: () => profile })
    board.setSource(source)
    await board.refreshJobs()
    expect(board.get().profile).toBe('coder')
    expect(board.get().jobs.map((job) => job.id)).toEqual(['a', 'b'])
    expect(board.isCurrent()).toBe(true)

    profile = 'default'
    expect(board.isCurrent()).toBe(false)
    const reading = board.refreshJobs()
    expect(board.get().jobs).toEqual([])
    await reading
    expect(board.get().jobs.map((job) => job.id)).toEqual(['d'])
    expect(source.calls).toEqual(['list coder', 'list default'])
  })

  test('a read that comes back after the profile changed is dropped', async () => {
    let profile = 'coder'
    const board = new CronBoard({ listProfile: () => profile })
    board.setSource(new FakeCronSource({ coder: [cronJob({ id: 'c' })] }))
    const reading = board.refreshJobs()
    profile = 'default'
    await reading
    expect(board.get().profile).toBeUndefined()
    expect(board.get().jobs).toEqual([])
  })

  test('actions update the job in place', async () => {
    const source = new FakeCronSource({ coder: [cronJob({ id: 'a', name: 'Brief', deliver: 'local' })] })
    const board = new CronBoard({ listProfile: () => 'coder' })
    board.setSource(source)
    await board.refreshJobs()
    const job = board.get().jobs[0]!

    await board.pause(job)
    expect(board.get().jobs[0]!.state).toBe('paused')
    await board.resume(job)
    expect(board.get().jobs[0]!.state).toBe('scheduled')
    await board.setDelivery(job, 'local,bot-chat')
    expect(source.updates).toEqual([{ deliver: 'local,bot-chat' }])
    const running = board.trigger(job)
    expect(board.get().triggering).toEqual(['a'])
    await running
    expect(board.get().triggering).toEqual([])
    expect(board.get().runs.a).toHaveLength(1)
    await board.delete(job)
    expect(board.get().jobs).toEqual([])
    expect(source.calls).toEqual(['list coder', 'pause a', 'resume a', 'update a', 'trigger a', 'runs a', 'delete a'])
  })

  test('a one-shot that removed itself re-reads the list', async () => {
    const source = new FakeCronSource({ coder: [cronJob({ id: 'once' })] })
    source.triggerError = new DashboardRequestError(404, 'Job not found')
    const board = new CronBoard({ listProfile: () => 'coder' })
    board.setSource(source)
    await board.refreshJobs()
    await board.trigger(board.get().jobs[0]!)
    expect(source.calls).toEqual(['list coder', 'trigger once', 'list coder'])
  })

  test('creating re-reads the list; errors are kept for the tab', async () => {
    const source = new FakeCronSource({ coder: [] })
    const board = new CronBoard({ listProfile: () => 'coder' })
    board.setSource(source)
    await board.refreshJobs()
    await board.create({ ...newCronDraft(), prompt: 'p' })
    expect(board.get().jobs.map((job) => job.id)).toEqual(['new'])
    source.cronJobs = async () => { throw new Error('Unknown profile') }
    await board.refreshJobs()
    expect(board.get().error).toBe('Unknown profile')
  })

  test('without REST the tab says so', async () => {
    const board = new CronBoard({ listProfile: () => 'coder' })
    await board.refreshJobs()
    expect(board.get().isAvailable).toBe(false)
  })

  test('the model catalog keeps providers with models', async () => {
    const board = new CronBoard({
      listProfile: () => 'coder',
      modelOptions: async () => ({ providers: [
        { slug: 'anthropic', name: 'Anthropic', models: ['claude-haiku-5-5'], authenticated: true },
        { slug: 'empty', name: 'Empty', models: [] },
      ] }),
    })
    expect((await board.modelCatalog()).providers.map((row) => row.slug)).toEqual(['anthropic'])
  })
})
