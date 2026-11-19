import { beforeAll, describe, expect, test } from 'vitest'
import { bucketTitle, dateBucket, effectiveTimes, sessionDateGroups, type SessionDateBucket } from '../../src/index.ts'

declare const process: { env: Record<string, string | undefined> }

// After HermesKit's SessionDateGroupsTests: New York time, weeks from Sunday.
beforeAll(() => { process.env.TZ = 'America/New_York' })

const date = (year: number, month: number, day: number, hour = 12, minute = 0) =>
  new Date(year, month - 1, day, hour, minute).getTime()
/** Tuesday, 27 October 2026, 3 PM. */
const now = () => date(2026, 10, 27, 15)
const kinds = (buckets: (SessionDateBucket | undefined)[]) => buckets.map((bucket) => bucket && bucketTitle(bucket))

describe('session date groups', () => {
  test('buckets coarsen with age', () => {
    const bucket = (time: number) => dateBucket(time, now())
    expect(bucket(date(2026, 10, 27, 9))).toEqual({ kind: 'today' })
    expect(bucket(date(2026, 10, 26, 9))).toEqual({ kind: 'yesterday' })
    expect(bucket(date(2026, 10, 25, 9))).toEqual({ kind: 'thisWeek' })
    expect(bucket(date(2026, 10, 24, 9))).toEqual({ kind: 'lastWeek' })
    expect(bucket(date(2026, 10, 18, 9))).toEqual({ kind: 'lastWeek' })
    expect(bucket(date(2026, 10, 17, 9))).toEqual({ kind: 'thisMonth' })
    expect(bucket(date(2026, 9, 30))).toEqual({ kind: 'month', year: 2026, month: 9 })
    expect(bucket(date(2025, 12, 1))).toEqual({ kind: 'monthYear', year: 2025, month: 12 })
    // A Monday-first locale moves Sunday into last week.
    expect(dateBucket(date(2026, 10, 25, 9), now(), { weekStart: 1 })).toEqual({ kind: 'lastWeek' })
  })

  test('the day ends at 4 AM', () => {
    expect(dateBucket(date(2026, 10, 27, 1), now())).toEqual({ kind: 'yesterday' })
    expect(dateBucket(date(2026, 10, 27, 4), now())).toEqual({ kind: 'today' })
    expect(dateBucket(date(2026, 10, 27, 23), date(2026, 10, 28, 2))).toEqual({ kind: 'today' })
  })

  test('titles follow Desktop', () => {
    expect(bucketTitle({ kind: 'today' })).toBe('Earlier today')
    expect(bucketTitle({ kind: 'lastWeek' })).toBe('Last week')
    expect(bucketTitle({ kind: 'month', year: 2026, month: 9 })).toBe('September')
    expect(bucketTitle({ kind: 'monthYear', year: 2025, month: 12 })).toBe('December 2025')
  })

  test('the head is the newest run, cut at a real break', () => {
    const times = [
      date(2026, 10, 27, 14, 50), date(2026, 10, 27, 14, 45), date(2026, 10, 27, 14, 40),
      date(2026, 10, 27, 14, 35), date(2026, 10, 27, 14, 30), date(2026, 10, 27, 14, 25),
      date(2026, 10, 27, 13), date(2026, 10, 27, 10), date(2026, 10, 26, 20),
    ]
    const groups = sessionDateGroups(times.map((_, index) => index), times, now())
    expect(kinds(groups.map((group) => group.bucket))).toEqual([undefined, 'Earlier today', 'Yesterday'])
    expect(groups.map((group) => group.items)).toEqual([[0, 1, 2, 3, 4, 5], [6, 7], [8]])
  })

  test('a burst is never sliced', () => {
    const times = Array.from({ length: 12 }, (_, index) => date(2026, 10, 27, 14, 55 - index * 2))
    const groups = sessionDateGroups(times.map((_, index) => index), times, now())
    expect(groups).toHaveLength(1)
    expect(groups[0]!.bucket).toBeUndefined()
  })

  test('a head that is only the top of its group dissolves', () => {
    const times = [date(2026, 10, 22), date(2026, 10, 21), date(2026, 9, 2)]
    const groups = sessionDateGroups([0, 1, 2], times, now())
    expect(kinds(groups.map((group) => group.bucket))).toEqual([undefined, 'September'])
    expect(groups.map((group) => group.items)).toEqual([[0, 1], [2]])
  })

  test('rows not read yet keep the group above', () => {
    const times = [undefined, date(2026, 10, 27, 14), undefined, date(2026, 10, 20), undefined, undefined]
    const groups = sessionDateGroups([0, 1, 2, 3, 4, 5], times, now())
    expect(kinds(groups.map((group) => group.bucket))).toEqual([undefined, 'Last week'])
    expect(groups.map((group) => group.items)).toEqual([[0, 1, 2], [3, 4, 5]])
  })

  test('a time newer than the row above follows the list order', () => {
    expect(effectiveTimes([date(2026, 9, 1), date(2026, 10, 27, 14)], 2)).toEqual([date(2026, 9, 1), date(2026, 9, 1)])
  })

  test('nothing read is one group', () => {
    expect(sessionDateGroups(['a', 'b'], [undefined, undefined], now())).toEqual([{ items: ['a', 'b'], id: 'recent' }])
    expect(sessionDateGroups([], [], now())).toEqual([])
  })
})
