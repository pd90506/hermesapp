import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { CronBoard, cronJob, type CronJob, type CronSource, type JSONValue } from '@talaria/hermes-core'
import { CronJobsView } from '../../src/renderer/features/cron/CronJobsList.tsx'

const now = Date.UTC(2026, 10, 19, 12, 0)

class Source implements CronSource {
  readonly calls: string[] = []
  readonly bodies: JSONValue[] = []
  constructor(public jobs: CronJob[]) {}
  private find(id: string) { return this.jobs.find((job) => job.id === id)! }
  async cronJobs() { this.calls.push('list'); return [...this.jobs] }
  async cronRuns(id: string) {
    this.calls.push(`runs ${id}`)
    return [
      { id: `cron_${id}_20261119_090000`, source: 'cron', lastActive: now / 1000 - 3 * 3600 },
      { id: `cron_output:${id}:2026-11-18`, source: 'cron_output', preview: 'disk 41%', startedAt: now / 1000 - 27 * 3600 },
    ]
  }
  async cronDeliveryTargets() { return [{ id: 'local', name: 'Local (save only)', homeTargetSet: true }] }
  async pauseCronJob(id: string) {
    this.calls.push(`pause ${id}`)
    return { ...this.find(id), state: 'paused' }
  }
  async resumeCronJob(id: string) { this.calls.push(`resume ${id}`); return this.find(id) }
  async triggerCronJob(id: string) { this.calls.push(`trigger ${id}`); return this.find(id) }
  async updateCronJob(id: string, _profile: string, updates: { [key: string]: JSONValue }) {
    this.calls.push(`update ${id}`)
    this.bodies.push(updates)
    return { ...this.find(id), deliver: String(updates.deliver) }
  }
  async deleteCronJob(id: string) {
    this.calls.push(`delete ${id}`)
    this.jobs = this.jobs.filter((job) => job.id !== id)
  }
  async createCronJob(_profile: string, body: { [key: string]: JSONValue }) {
    this.calls.push('create')
    this.bodies.push(body)
    const job = cronJob({ id: 'new', prompt: String(body.prompt) })
    this.jobs.push(job)
    return job
  }
  async cronBlueprints() { return [] }
  async instantiateCronBlueprint() { return cronJob({ id: 'bp' }) }
}

async function show(jobs: CronJob[], connected = true) {
  const source = new Source(jobs)
  const board = new CronBoard({ listProfile: () => 'coder' })
  board.setSource(source)
  render(<CronJobsView board={board} connected={connected} listProfile="coder" now={now} />)
  if (connected) await waitFor(() => expect(source.calls).toContain('list'))
  return { source, board }
}

afterEach(cleanup)

describe('Cron Jobs tab', () => {
  it('says so when not connected', async () => {
    await show([], false)
    expect(screen.getByText('Connect to see scheduled jobs')).toBeTruthy()
  })

  it('shows an empty profile with New Cron Job', async () => {
    await show([])
    await screen.findByText('No cron jobs')
    expect((screen.getByTestId('newCronJob') as HTMLButtonElement).disabled).toBe(false)
  })

  it('shows a job’s next run, schedule, delivery and last failure', async () => {
    await show([
      cronJob({ id: 'a', name: 'Morning brief', scheduleDisplay: '0 9 * * *', deliver: 'bot-chat,local',
        nextRunAt: now + 2 * 3600_000, lastStatus: 'error', lastError: 'timeout' }),
      cronJob({ id: 'b', name: 'Paused one', state: 'paused' }),
    ])
    await screen.findByText('Morning brief')
    expect(screen.getByText('in 2 hours')).toBeTruthy()
    await waitFor(() => expect(screen.getByTestId('cronJob.a').textContent).toContain('0 9 * * *  → Bot Chat, Local (save only)'))
    expect(screen.getByText('Last run failed: timeout')).toBeTruthy()
    expect(screen.getByText('Paused')).toBeTruthy()
  })

  it('a click shows the job’s runs; a script run shows its output', async () => {
    const { source } = await show([cronJob({ id: 'a', name: 'Brief' })])
    fireEvent.click(await screen.findByText('Brief'))
    await screen.findByText('disk 41%')
    expect(source.calls).toContain('runs a')
    expect(screen.getByTestId('cronRun.cron_a_20261119_090000')).toBeTruthy()
    fireEvent.click(screen.getByText('Brief'))
    expect(screen.queryByText('disk 41%')).toBeNull()
  })

  it('the “…” menu pauses, sets delivery and deletes after asking', async () => {
    const { source } = await show([cronJob({ id: 'a', name: 'Brief', deliver: 'local' })])
    await screen.findByText('Brief')
    fireEvent.click(screen.getByTestId('cronJobMenu.a'))
    fireEvent.click(screen.getByText('Pause'))
    await waitFor(() => expect(source.calls).toContain('pause a'))
    await screen.findByText('Paused')

    fireEvent.click(screen.getByTestId('cronJobMenu.a'))
    expect(screen.getByText('Resume')).toBeTruthy()
    fireEvent.click(screen.getByText('Deliver To'))
    fireEvent.click(screen.getByText('Bot Chat'))
    await waitFor(() => expect(source.bodies).toEqual([{ deliver: 'local,bot-chat' }]))

    fireEvent.contextMenu(screen.getByTestId('cronJob.a'))
    fireEvent.click(screen.getByText('Delete…'))
    expect(screen.getByText('Delete “Brief”?')).toBeTruthy()
    fireEvent.click(screen.getByText('Delete'))
    await waitFor(() => expect(source.calls).toContain('delete a'))
    await waitFor(() => expect(screen.queryByText('Brief')).toBeNull())
  })

  it('New Cron Job checks the form, then creates the job', async () => {
    const { source } = await show([])
    fireEvent.click(await screen.findByTestId('newCronJob'))
    const editor = screen.getByTestId('cronEditor')
    expect(editor.textContent).toContain('Every day at 9:00')
    fireEvent.click(screen.getByTestId('cronEditorSave'))
    expect(screen.getByTestId('cronEditorError').textContent).toBe('Enter a prompt.')
    fireEvent.change(screen.getByTestId('cronEditorPrompt'), { target: { value: 'Summarize the news' } })
    fireEvent.change(screen.getByTestId('cronEditorFrequency'), { target: { value: 'weekdays' } })
    await act(async () => { fireEvent.click(screen.getByTestId('cronEditorSave')) })
    await waitFor(() => expect(source.calls).toContain('create'))
    expect(source.bodies[0]).toEqual({ prompt: 'Summarize the news', schedule: '0 9 * * 1-5', deliver: 'local' })
    await waitFor(() => expect(screen.queryByTestId('cronEditor')).toBeNull())
  })
})
