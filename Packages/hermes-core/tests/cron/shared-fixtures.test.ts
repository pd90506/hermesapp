import { describe, expect, test } from 'vitest'
import fixture from '../../../fixtures/cron-jobs.json' with { type: 'json' }
import {
  cronJobTitle, deliveryTargets, deliversToBotChat, effectiveState, isRunSessionID, isScriptOnly, needsAttention,
  parseCronJob, parseCronSchedule, scheduleExpression, toggleDelivery,
} from '../../src/index.ts'

// The same cases as HermesKit's SharedFixtureTests.swift (Packages/fixtures/README.md).

describe('cron-jobs.json', () => {
  test.each(fixture.jobs)('reads $expected.id', ({ row, expected }) => {
    const job = parseCronJob(row)!
    expect(job.id).toBe(expected.id)
    expect(cronJobTitle(job)).toBe(expected.title)
    expect(job.scheduleDisplay).toBe(expected.scheduleDisplay)
    expect(job.scheduleExpression).toBe(expected.scheduleExpression)
    expect(effectiveState(job)).toBe(expected.state)
    expect(deliveryTargets(job)).toEqual(expected.deliveryTargets)
    expect(deliversToBotChat(job)).toBe(expected.deliversToBotChat)
    expect(job.nextRunAt ?? null).toBe(expected.nextRunAt)
    expect(job.lastRunAt ?? null).toBe(expected.lastRunAt)
    expect(isScriptOnly(job)).toBe(expected.isScriptOnly)
    expect(job.model ?? null).toBe(expected.model)
    expect(needsAttention(job)).toBe(expected.needsAttention)
  })

  test.each(fixture.schedules)('schedule $expression', (item) => {
    const schedule = parseCronSchedule(item.expression)
    expect(schedule.frequency).toBe(item.frequency)
    if ('hour' in item) expect(schedule.hour).toBe(item.hour)
    if ('minute' in item) expect(schedule.minute).toBe(item.minute)
    if ('weekday' in item) expect(schedule.weekday).toBe(item.weekday)
    if ('dayOfMonth' in item) expect(schedule.dayOfMonth).toBe(item.dayOfMonth)
    expect(scheduleExpression(schedule)).toBe(item.back)
  })

  test.each(fixture.toggles)('toggles $target in $deliver', (item) => {
    expect(toggleDelivery(item.deliver ?? undefined, item.target, item.on)).toBe(item.result)
  })

  test.each(fixture.runSessionIDs)('run session id $id', (item) => {
    expect(isRunSessionID(item.id)).toBe(item.run)
  })
})
