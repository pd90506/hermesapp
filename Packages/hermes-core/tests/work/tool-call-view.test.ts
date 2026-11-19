import { describe, expect, test } from 'vitest'
import {
  ToolCallViews, ToolResultText, backgroundNotice, blockKind, makeItem, parseBackgroundNotice, parseReviewNote,
  reviewDisplayKind, reviewNote, storedItems, toolCallView, transcriptBlocks,
  type JSONValue, type ToolPhase, type TranscriptItem,
} from '../../src/index.ts'

// Ported from HermesKit's ToolCallViewTests, BackgroundNoticeTests and the review-note tests.

function call(name: string, options: { args?: JSONValue; result?: JSONValue; phase?: ToolPhase; error?: string; inlineDiff?: string } = {}): TranscriptItem {
  const phase = options.phase ?? 'complete'
  return {
    ...makeItem('t', 'tool', '', phase === 'running'),
    toolName: name,
    tool: {
      toolID: 't', name, phase,
      ...(options.args !== undefined ? { args: options.args } : {}),
      ...(options.result !== undefined ? { result: options.result } : {}),
      ...(options.error !== undefined ? { error: options.error } : {}),
      ...(options.inlineDiff !== undefined ? { inlineDiff: options.inlineDiff } : {}),
    },
  }
}

const path = '/home/u/papers/2026-wiechman-institutional-system-robustness.md'

describe('tool calls', () => {
  test('a read names its file and lines and opens to them', () => {
    const content = '237|To address the limitations\n238|Institutional costs, flexibility, and\n259|end'
    const view = toolCallView(call('read_file', { args: { path, offset: 237, limit: 23 }, result: { content, total_lines: 400 } }))
    expect(view.title).toBe('Read 2026-wiechman-institutional-system-robustness.md L237-259')
    expect(view.status).toBe('success')
    expect(ToolCallViews.isExpandable(view) && ToolCallViews.showsDetail(view) && ToolCallViews.rendersDetailAsCode(view)).toBe(true)
    expect(view.detail).toBe(content)
    expect(ToolCallViews.opensByDefault(view)).toBe(false)
  })

  test('a read without an offset takes its lines from the content', () => {
    expect(toolCallView(call('read_file', { args: { path: 'a/notes.md', limit: 50 }, result: { content: '1|# Notes\n2|\n3|end' } })).title)
      .toBe('Read notes.md L1-3')
    expect(toolCallView(call('read_file', { args: { path: 'a/notes.md' }, result: { content: '1|x' } })).title).toBe('Read notes.md')
  })

  test('a stored read keeps its result', () => {
    const items = storedItems([
      { id: 1, role: 'assistant', content: '', tool_calls: [{ id: 'call_1', function: { name: 'read_file', arguments: `{"path":"${path}","offset":237,"limit":23}` } }] },
      { id: 2, role: 'tool', content: '{"content": "237|To address", "total_lines": 400}', tool_call_id: 'call_1' },
    ], new Map())
    const tool = items.find((item) => item.role === 'tool')!
    const view = toolCallView(tool)
    expect(view.title).toBe('Read 2026-wiechman-institutional-system-robustness.md L237-259')
    expect(view.detail).toBe('237|To address')
    expect(ToolCallViews.showsDetail(view)).toBe(true)
  })

  test('a command shows its prompt, exit code and output', () => {
    const view = toolCallView(call('terminal', {
      args: { command: 'cd /repo && git status 2>&1 | tail -5' }, result: { output: 'On branch main\nnothing to commit', exit_code: 0 },
    }))
    expect(view.title).toBe('Ran git status')
    expect(view.terminalCommand).toBe('cd /repo && git status 2>&1 | tail -5')
    expect(view.terminalExitCode).toBe(0)
    expect(view.detail).toBe('On branch main\nnothing to commit')
    expect(ToolCallViews.showsDetail(view) && ToolCallViews.rendersDetailAsCode(view)).toBe(true)
    const running = toolCallView(call('terminal', { args: { command: 'make' }, phase: 'running' }))
    expect([running.title, running.status, running.isPending]).toEqual(['Running make', 'running', true])
  })

  test('an exit code without output is a notice or an error', () => {
    const one = toolCallView(call('terminal', { args: { command: 'grep x f' }, result: { output: '', exit_code: 1 } }))
    expect(one.status).toBe('notice')
    expect(one.detail).toBe('Command failed with exit code 1.')
    expect(ToolCallViews.showsDetail(one)).toBe(true)
    const two = toolCallView(call('terminal', { args: { command: 'false' }, result: { output: '', exit_code: 2 } }))
    expect(two.status).toBe('error')
    expect(ToolCallViews.errorSummary(two)).toBe('Command failed with exit code 2.')
    expect(toolCallView(call('terminal', { args: { command: 'grep x f' }, result: { output: 'x', exit_code: 1 } })).status).toBe('success')
  })

  test('a search lists its hits and counts them', () => {
    const result: JSONValue = { data: { web: [
      { title: 'Swift Grid', url: 'https://example.com/grid', description: 'Lay out views[1].' },
      { title: 'Docs', url: 'https://example.com/docs' },
    ] } }
    const view = toolCallView(call('web_search', { args: { query: 'swift grid' }, result }))
    expect(view.title).toBe('Searched “swift grid”')
    expect(view.countLabel).toBe('2 results')
    expect(view.searchQuery).toBe('swift grid')
    expect(view.searchHits.map((hit) => hit.title)).toEqual(['Swift Grid', 'Docs'])
    expect(view.searchHits[0]!.snippet).toBe('Lay out views.')
    expect(ToolCallViews.isExpandable(view)).toBe(true)
  })

  test('a failed call opens to its error', () => {
    const view = toolCallView(call('web_extract', { args: { urls: ['https://example.com/a'] }, result: { success: false, error: '403 Forbidden' }, phase: 'failed' }))
    expect(view.status).toBe('error')
    expect(ToolCallViews.errorSummary(view)).toBe('403 Forbidden')
    expect(ToolCallViews.showsDetail(view)).toBe(true)
    expect(view.detailLabel).toBe('Error details')
    const missing = toolCallView(call('read_file', { args: { path: 'x.md' }, result: { error: 'File not found: x.md' } }))
    expect([missing.status, missing.title]).toEqual(['notice', 'Read x.md'])
  })

  test('edits open to their diff and diff-less ones hide', () => {
    const view = toolCallView(call('patch', { args: { path: 'Sources/A.swift' }, result: { success: true }, inlineDiff: '--- a/A.swift\n+++ b/A.swift\n-old\n+new' }))
    expect(view.title).toBe('A.swift')
    expect(ToolCallViews.opensByDefault(view)).toBe(true)
    expect(ToolCallViews.showsDetail(view)).toBe(false)
    expect(ToolCallViews.isHidden(view)).toBe(false)
    expect(ToolCallViews.diffStats(view.inlineDiff)).toEqual({ added: 1, removed: 1 })
    expect(ToolCallViews.isHidden(toolCallView(call('write_file', { args: { path: 'B.md' }, result: { bytes_written: 3 } })))).toBe(true)
    const running = toolCallView(call('write_file', { args: { path: 'B.md' }, phase: 'running' }))
    expect(ToolCallViews.isHidden(running)).toBe(false)
    expect(running.title).toBe('B.md')
  })

  test('other tools show a summary of their result', () => {
    const view = toolCallView(call('custom_lookup', { args: { id: 7 }, result: { path: 'notes.md', bytes: 12 } }))
    expect(view.title).toBe('Custom Lookup')
    expect(view.detail).toBe('- Path: notes.md\n- Bytes: 12')
    expect(toolCallView(call('browser_scroll', { result: { ok: true } })).title).toBe('Browser Scroll')
    expect(toolCallView(call('memory', { result: { success: true, message: 'Saved.' } })).title).toBe('Saved to memory')
    expect(toolCallView(call('skill_view', { args: { name: 'swiftui' }, result: { success: true } })).title).toBe('Loaded skill: swiftui')
  })

  test('a call that ended without a result says so', () => {
    const view = toolCallView(call('terminal', { args: { command: 'sleep 99' } }))
    expect([view.title, view.status]).toEqual(['Result unavailable', 'warning'])
  })

  test('row titles', () => {
    const title = (item: TranscriptItem, result: JSONValue | 'none' = { output: '', exit_code: 0 }) =>
      toolCallView({ ...item, tool: { ...item.tool!, ...(result !== 'none' ? { result } : {}) } }).title
    expect(title(call('terminal', { args: { command: 'git status' } }))).toBe('Ran git status')
    expect(title({ ...call('terminal'), detail: 'make test', tool: { ...call('terminal').tool!, context: 'make test' } })).toBe('Ran make test')
    expect(title(call('read_file', { args: '{"path":"x/y.md"}' }), { content: '1|a' })).toBe('Read y.md')
    expect(title(call('web_extract', { args: { urls: ['https://example.com/docs'] } }), { results: [] })).toBe('Read example.com/docs')
    expect(title(call('terminal', { args: { command: 'ls' } }), 'none')).toBe('Result unavailable')
    expect(title(call('terminal', { args: { command: 'ls' }, phase: 'running' }), 'none')).toBe('Running ls')
  })

  test('result summaries match Desktop', () => {
    expect(ToolResultText.summary({ message: 'Done.' })).toBe('Done.')
    expect(ToolResultText.summary({ data: { items: ['a', 'b'] } })).toBe('- Items: a, b')
    expect(ToolResultText.summary(['x', 'y'])).toBe('- x\n- y')
    expect(ToolResultText.errorMessage({ error: 'boom' })).toBe('boom')
    expect(ToolResultText.errorMessage({ error: null, output: 'error: not really' })).toBe('')
    expect(ToolResultText.errorMessage({ success: false, data: { error: 'nope' } })).toBe('nope')
  })

  test('long text is clamped for display', () => {
    expect(ToolCallViews.clampForDisplay('abcdef', 4)).toBe('abcd\n\n… 2 more characters truncated')
    expect(ToolCallViews.stripANSI('\u001B[31mred\u001B[0m')).toBe('red')
  })
})

const completion = `[IMPORTANT: Background process proc_3f2a completed normally (exit code 0).
Command: python3 build.py
Output:
done in 4s]`

describe('background notices', () => {
  test('a process completion is a notice', () => {
    expect(parseBackgroundNotice(completion)).toEqual({
      headline: 'Background process proc_3f2a completed normally (exit code 0).',
      detail: 'Command: python3 build.py\nOutput:\ndone in 4s',
    })
  })

  test('heartbeats and subagent results are notices', () => {
    const heartbeat = parseBackgroundNotice('[Background process proc_1 heartbeat #2 — still running after 1m (next in 60s).\nCommand: sleep 100\nOutput since last heartbeat:\n]')
    expect(heartbeat!.headline.startsWith('Background process proc_1 heartbeat #2')).toBe(true)
    expect(parseBackgroundNotice('[ASYNC DELEGATION COMPLETE — d_9]\nA background subagent you dispatched earlier has finished.')!.headline)
      .toBe('[ASYNC DELEGATION COMPLETE — d_9]')
    expect(parseBackgroundNotice('A background subagent you dispatched earlier has finished. Result: ok')).toBeDefined()
  })

  test('what the user types is not', () => {
    expect(parseBackgroundNotice('Please run the background process again')).toBeUndefined()
    expect(parseBackgroundNotice('[IMPORTANT: read this]')).toBeUndefined()
    expect(backgroundNotice(makeItem('a', 'assistant', completion))).toBeUndefined()
  })

  test('a notice and a review line have their own renderers', () => {
    const notice = makeItem('n', 'user', completion)
    const review = { ...makeItem('r', 'system', '💾 Self-improvement review: Memory updated'), displayKind: reviewDisplayKind }
    const blocks = transcriptBlocks([notice, review], false)
    expect(blocks.map(blockKind)).toEqual(['backgroundNotice', 'review'])
  })
})

describe('review notes', () => {
  test('a review note reads like Desktop', () => {
    expect(parseReviewNote('Memory updated')).toEqual({ label: 'Memory updated', detail: '' })
    expect(parseReviewNote('Review\nUser profile updated')).toEqual({ label: 'Review', detail: 'User profile updated' })
    expect(parseReviewNote(':x')).toBeUndefined()
    const row = { ...makeItem('r', 'system', "💾 Self-improvement review: Memory updated · Skill 'tea' patched"), displayKind: reviewDisplayKind }
    expect(reviewNote(row)).toEqual({ label: 'Self-improvement review', detail: "Memory updated · Skill 'tea' patched" })
    expect(reviewNote(makeItem('s', 'system', 'Self-improvement review: x'))).toBeUndefined()
  })
})
