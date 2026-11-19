import { describe, expect, it } from 'vitest'
import {
  SessionUsageTracker, contextGauge, contextSummary, formatTokens, mergeSessionUsage, parseContextBreakdown,
  parseSessionUsage, unitemizedTokens,
} from '../../src/index.ts'

// After HermesKit's SessionUsageTests.

describe('session usage', () => {
  it('reads `_get_usage`', () => {
    const usage = parseSessionUsage({ input: 1200, output: 300, total: 1500, calls: 2, context_used: 30_000,
      context_max: 200_000, context_percent: 15, cache_hit_pct: 80, avg_tps: 41.6, cost_usd: 0.0123, model: 'm' })
    expect(usage).toMatchObject({ total: 1500, calls: 2, contextUsed: 30_000, contextMax: 200_000, contextPercent: 15,
      cacheHitPercent: 80, tokensPerSecond: 41.6, costUSD: 0.0123, model: 'm', contextEstimated: false })
    expect(parseSessionUsage({ model: 'only' })).toBeUndefined()
    expect(parseSessionUsage('nope')).toBeUndefined()
    expect(parseSessionUsage({ total: 1, context_max: 0 })?.contextMax).toBeUndefined()
  })

  it('keeps the occupancy a report without one lacks', () => {
    const older = parseSessionUsage({ total: 10, context_used: 50, context_max: 100, context_percent: 50 })!
    const newer = parseSessionUsage({ total: 20, calls: 3 })!
    expect(mergeSessionUsage(older, newer)).toMatchObject({ total: 20, calls: 3, contextUsed: 50, contextMax: 100, contextPercent: 50 })
    const measured = parseSessionUsage({ total: 30, context_used: 10, context_max: 100 })!
    expect(mergeSessionUsage(older, measured).contextUsed).toBe(10)
  })

  it('reads a breakdown and drops a zeroed one', () => {
    const breakdown = parseContextBreakdown({ context_used: 1000, context_max: 8000, context_percent: 12.5,
      categories: [{ id: 'system', label: 'System prompt', tokens: 400 }, { id: 'empty', tokens: 0 }, { id: 'tools', tokens: 300 }] })!
    expect(breakdown.categories.map((row) => row.id)).toEqual(['system', 'tools'])
    expect(breakdown.contextEstimated).toBe(true)
    expect(breakdown.contextPercent).toBe(13)
    expect(unitemizedTokens(breakdown, 1000)).toBe(300)
    expect(unitemizedTokens(breakdown, 100)).toBe(0)
    expect(parseContextBreakdown({ context_max: 0 })).toBeUndefined()
  })

  it('picks the gauge: the breakdown when idle, the streamed usage while running', () => {
    const usage = parseSessionUsage({ total: 1, context_used: 50_000, context_max: 200_000 })!
    const breakdown = parseContextBreakdown({ context_used: 9000, context_max: 200_000, context_percent: 5, context_estimated: true })!
    expect(contextGauge({ usage, breakdown }, false)).toEqual({ used: 9000, max: 200_000, percent: 5, isEstimated: true })
    expect(contextGauge({ usage, breakdown }, true)).toEqual({ used: 50_000, max: 200_000, percent: 25, isEstimated: false })
    expect(contextGauge({}, false)).toBeUndefined()
    expect(contextSummary({ used: 30_000, max: 200_000, percent: 15, isEstimated: true })).toBe('~30K of 200K tokens (15%)')
    expect([formatTokens(950), formatTokens(12_800), formatTokens(1_234_567)]).toEqual(['950', '12.8K', '1.23M'])
  })

  it('follows the events', () => {
    const tracker = new SessionUsageTracker()
    tracker.takeInfo({ total: 5, context_used: 10, context_max: 100 })
    expect(tracker.get().usage?.contextUsed).toBe(10)
    tracker.observe({ type: 'session.usage', payload: { usage: { total: 9, calls: 1 } } })
    expect(tracker.get().usage).toMatchObject({ total: 9, contextUsed: 10 })
    tracker.observe({ type: 'message.complete', payload: { usage: { total: 12, context_used: 40, context_max: 100 } } })
    expect(tracker.get().usage?.contextUsed).toBe(40)
    tracker.observe({ type: 'message.delta', payload: { text: 'x' } })
    expect(tracker.get().usage?.total).toBe(12)
  })
})
