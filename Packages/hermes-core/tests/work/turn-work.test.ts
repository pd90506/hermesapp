import { describe, expect, test } from 'vitest'
import {
  StepGroups, ToolCallSummary, WorkSteps, blockIDContaining, makeItem, settledTitle, storedItems, toolDiff,
  transcriptBlocks, workDuration,
  type JSONValue, type ToolPhase, type TranscriptBlock, type TranscriptItem, type TurnWork, type WorkEntry,
} from '../../src/index.ts'

// Ported from HermesKit's TurnWorkTests and ToolCallSummaryTests.

export function user(id: string, steer = false): TranscriptItem {
  return { ...makeItem(id, 'user', 'question'), ...(steer ? { displayKind: 'steer' } : {}) }
}

export function reply(id: string, text: string, options: { interim?: boolean; active?: boolean; reasoning?: string } = {}): TranscriptItem {
  return { ...makeItem(id, 'assistant', text, options.active ?? false), isInterim: options.interim ?? false, reasoning: options.reasoning ?? '' }
}

export function tool(id: string, name: string, options: { args?: JSONValue; context?: string; phase?: ToolPhase } = {}): TranscriptItem {
  const phase = options.phase ?? 'complete'
  const item: TranscriptItem = {
    ...makeItem(id, 'tool', '', phase === 'running'),
    toolName: name,
    tool: {
      toolID: id, name, phase,
      ...(options.args !== undefined ? { args: options.args } : {}),
      ...(options.context !== undefined ? { context: options.context } : {}),
    },
    ...(options.context !== undefined ? { detail: options.context } : {}),
  }
  return item
}

const at = (seconds: number, item: TranscriptItem): TranscriptItem => ({ ...item, timestamp: seconds * 1000 })

function entry(value: WorkEntry): string {
  if (value.kind === 'commentary') return 'c:' + value.item.id
  if (value.kind === 'card') return 'card:' + value.item.id
  return '[' + value.group.steps.map((step) => (step.kind === 'think' ? '~' + step.item.id : step.id)).join(',') + ']'
    + (value.group.isLive ? '*' : '')
}

function kinds(blocks: readonly TranscriptBlock[]): string[] {
  return blocks.map((block) => block.kind === 'item'
    ? block.item.id
    : `work(${block.work.entries.map(entry).join(' ')})${block.work.isLive ? '*' : ''}`)
}

const works = (blocks: readonly TranscriptBlock[]): TurnWork[] => blocks.flatMap((block) => (block.kind === 'work' ? [block.work] : []))

describe('grouping', () => {
  test('a settled turn folds its work before the answer', () => {
    const items = [
      user('u1'), reply('a1', 'Let me look.', { interim: true, reasoning: 'Plan the search.' }),
      tool('t1', 'terminal', { args: { command: 'ls' } }),
      tool('t2', 'read_file', { args: { path: 'a.md' } }),
      reply('a2', 'Now the image.', { interim: true }),
      tool('t3', 'vision_analyze'),
      reply('r1', '', { reasoning: 'Which file next?' }),
      tool('t4', 'read_file', { args: { path: 'b.md' } }),
      reply('a3', '| a | b |\n|---|---|\n| 1 | 2 |', { reasoning: 'All read.' }),
    ]
    const blocks = transcriptBlocks(items, false)
    expect(kinds(blocks)).toEqual(['u1', 'work(c:a1 [~a1,t1,t2] c:a2 [t3,~r1,t4,~a3])', 'a3'])
    const work = works(blocks)[0]!
    expect(work.items.map((item) => item.id)).toEqual(['a1', 't1', 't2', 'a2', 't3', 'r1', 't4'])
    const last = blocks[blocks.length - 1]!
    expect(last.kind === 'item' && last.item.reasoning).toBe('')
    const first = work.entries[0]!
    expect(first.kind === 'commentary' && first.item.reasoning).toBe('')
  })

  test('a plain answer has no work', () => {
    const items = [user('u1'), reply('a1', 'Plain.'), user('u2'), reply('b1', 'Answer.', { reasoning: 'Easy.' })]
    const blocks = transcriptBlocks(items, false)
    expect(kinds(blocks)).toEqual(['u1', 'a1', 'u2', 'work([~b1])', 'b1'])
    expect(blocks[3]!.id).toBe('work-b1')
  })

  test('a running turn shows its work live', () => {
    const items = [
      user('u1'), reply('old', 'Earlier.'), user('u2'),
      tool('t1', 'terminal'), tool('t2', 'read_file'),
      reply('a1', 'Interim note.', { interim: true }),
      tool('t3', 'terminal', { phase: 'running' }),
      reply('blank', ''),
    ]
    const blocks = transcriptBlocks(items, true)
    expect(kinds(blocks)).toEqual(['u1', 'old', 'u2', 'work([t1,t2] c:a1 [t3]*)*'])
    expect(works(blocks)[0]!.items.at(-1)!.id).toBe('blank')
  })

  test('work is no longer live once the answer streams', () => {
    const items = [user('u1'), tool('t1', 'terminal'), reply('a1', 'Streaming…', { active: true })]
    expect(kinds(transcriptBlocks(items, true))).toEqual(['u1', 'work([t1])', 'a1'])
  })

  test('a turn ending with tools is all work', () => {
    const items = [user('u1'), reply('a1', 'Trying.'), tool('t1', 'terminal'), tool('t2', 'terminal')]
    expect(kinds(transcriptBlocks(items, false))).toEqual(['u1', 'work(c:a1 [t1,t2])'])
  })

  test('steer and system rows keep their places', () => {
    const items = [
      user('u1'), tool('t1', 'terminal'), user('s1', true),
      makeItem('sys', 'system', 'note'), tool('t2', 'terminal'), reply('a1', 'Done.'),
    ]
    expect(kinds(transcriptBlocks(items, false))).toEqual(['u1', 'work([t1])', 's1', 'sys', 'work([t2])', 'a1'])
  })

  test('cards keep their rows and edits are steps', () => {
    const items = [
      user('u1'), tool('t1', 'read_file'), tool('e1', 'patch'), tool('t2', 'terminal'),
      tool('d1', 'delegate_task'), tool('t3', 'terminal'), reply('a1', 'Done.'),
    ]
    const expected = ['u1', 'work([t1,e1,t2] card:d1 [t3])', 'a1']
    expect(kinds(transcriptBlocks(items, false))).toEqual(expected)
    expect(kinds(transcriptBlocks(items, true))).toEqual(expected)
  })

  test('a queued prompt is not listed', () => {
    const queued = { ...user('q1'), outgoingStatus: 'Queued' }
    expect(kinds(transcriptBlocks([user('u1'), reply('a1', 'Hi.'), queued], true))).toEqual(['u1', 'a1'])
  })

  test('work is timed from the prompt to the answer', () => {
    const items = [at(100, user('u1')), at(110, tool('t1', 'terminal')), at(145, reply('a1', 'Done.'))]
    const work = works(transcriptBlocks(items, false))[0]!
    expect(workDuration(work)).toBe(45)
    expect(settledTitle(workDuration(work), false)).toBe('Completed in 45s')
    expect(settledTitle(65, true)).toBe('Stopped after 1m 05s')
    expect(settledTitle(undefined, false)).toBe('Completed')

    const unanswered = [at(100, user('u1')), at(130, tool('t1', 'terminal'))]
    expect(workDuration(works(transcriptBlocks(unanswered, false))[0]!)).toBe(30)
    const live = works(transcriptBlocks(unanswered, true))[0]!
    expect(live.isLive).toBe(true)
    expect(live.endedAt).toBeUndefined()
    expect(live.startedAt).toBe(100_000)
  })

  test("a row's block is found after an older page renames its work", () => {
    const loaded = [tool('t2', 'terminal'), reply('a2', 'Done.'), user('u2'), reply('b1', 'Plain answer.')]
    const before = transcriptBlocks(loaded, false)
    expect(kinds(before)).toEqual(['work([t2])', 'a2', 'u2', 'b1'])
    expect(blockIDContaining('t2', before)).toBe('work-t2')
    const older = [user('u1'), reply('a1', 'Checking.'), tool('t1', 'terminal')]
    const after = transcriptBlocks([...older, ...loaded], false)
    expect(kinds(after)).toEqual(['u1', 'work(c:a1 [t1,t2])', 'a2', 'u2', 'b1'])
    expect(blockIDContaining('t2', after)).toBe('work-a1')
    expect(blockIDContaining('u2', after)).toBe('u2')
    expect(blockIDContaining('gone', after)).toBeUndefined()
  })

  test('text between steps splits the work into groups', () => {
    const items = [
      user('u1'), reply('r1', '', { reasoning: 'Plan the upgrade.' }),
      reply('a1', 'Understood — no backup.', { interim: true }),
      tool('t1', 'terminal'), tool('t2', 'mystery'), tool('t3', 'read_file'),
      reply('a2', 'Upgrade done.'),
    ]
    const blocks = transcriptBlocks(items, false)
    expect(kinds(blocks)).toEqual(['u1', 'work([~r1] c:a1 [t1,t2,t3])', 'a2'])
    const titles = works(blocks)[0]!.entries.flatMap((value) => (value.kind === 'group' ? [StepGroups.title(value.group)] : []))
    expect(titles).toEqual(['Analysis completed', 'Ran commands, called tools, read files'])
  })
})

describe('steps', () => {
  test('steps read as a kind and a line', () => {
    const thinking = reply('r1', '', { reasoning: '\n**Checking the build**\nThe log says…' })
    const think = { kind: 'think' as const, id: 'think-r1', item: thinking }
    expect(WorkSteps.kind(think)).toBe('Think')
    expect(WorkSteps.summary(think)).toBe('Checking the build')
    expect(WorkSteps.copyText(think)).toBe(thinking.reasoning)

    const step = (item: TranscriptItem) => ({ kind: 'tool' as const, id: item.id, item })
    const bash = step(tool('t1', 'terminal', { args: { command: 'git status\ngit log -1', workdir: '/repo/app' } }))
    expect(WorkSteps.kind(bash)).toBe('Bash')
    expect(WorkSteps.summary(bash)).toBe('git status')
    expect(WorkSteps.workdir(bash)).toBe('/repo/app')
    expect(WorkSteps.copyText(bash)).toBe('git status\ngit log -1')

    const read = step(tool('t2', 'read_file', { args: '{"path":"x/y.md"}' }))
    expect(WorkSteps.kind(read)).toBe('Read')
    expect(WorkSteps.summary(read)).toBe('x/y.md')
    expect(WorkSteps.workdir(read)).toBeUndefined()
    expect(WorkSteps.kind(step(tool('t3', 'browser_click')))).toBe('Browser')
    expect(WorkSteps.kind(step(tool('t4', 'mystery', { context: 'the thing' })))).toBe('mystery')
  })

  test('groups are named after what their calls did', () => {
    const read = tool('t1', 'read_file', { args: { path: 'a.swift' } })
    const build = tool('t2', 'terminal', { args: { command: 'swift build' }, phase: 'running' })
    const other = tool('t3', 'mystery')
    const edit = tool('t4', 'patch')
    expect(ToolCallSummary.groupTitle([build, read], false)).toBe('Ran commands, read files')
    expect(ToolCallSummary.groupTitle([read, build], true)).toBe('Read files, running commands')
    expect(ToolCallSummary.groupTitle([build, other, read, edit, build], false)).toBe('Ran commands, called tools, read files, etc.')
    expect(ToolCallSummary.groupTitle([], false)).toBe('Analysis completed')
    expect(ToolCallSummary.groupTitle([], true)).toBe('Analyzing')
    const five = tool('t5', 'terminal')
    const group = { id: 'g', steps: [{ kind: 'tool' as const, id: 't1', item: read }, { kind: 'tool' as const, id: 't5', item: five }], isLive: false }
    expect(StepGroups.title(group)).toBe('Read files, ran commands')
    expect(StepGroups.iconTool(group)).toBe('read_file')
  })
})

describe('summaries', () => {
  test('diffs come from the event or the stored result', () => {
    const live = tool('e1', 'patch')
    const liveItem = { ...live, tool: { ...live.tool!, inlineDiff: '\u001B[33m┊ review diff\n--- a/x\n+++ b/x\n-old\n+new\u001B[0m' } }
    expect(toolDiff(liveItem)).toBe('--- a/x\n+++ b/x\n-old\n+new')
    const stored = tool('e2', 'patch')
    const storedItem = { ...stored, tool: { ...stored.tool!, output: '{"success": true, "diff": "-a\\n+b"}' } }
    expect(toolDiff(storedItem)).toBe('-a\n+b')
    expect(toolDiff(tool('t', 'terminal'))).toBeUndefined()
  })

  test('diff boxes drop headers', () => {
    const diff = 'diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new'
    expect(ToolCallSummary.displayDiff(diff)).toBe(' keep\n-old\n+new')
  })

  test('the run line matches Desktop', () => {
    const tools = [tool('t1', 'vision_analyze'), tool('t2', 'terminal', { args: { command: 'ls' } }), tool('t3', 'terminal', { args: { command: 'pwd' } })]
    expect(ToolCallSummary.run(tools, false)).toBe('Analyzed 1 image, ran 2 commands')
    const edit = tool('t1', 'patch', { args: { path: '/repo/Sources/Transcript.swift' } })
    const search = tool('t2', 'web_search', { args: { query: 'swift grid' } })
    const skill = tool('t3', 'skill_view', { args: { name: 'swiftui' } })
    expect(ToolCallSummary.run([skill, edit, search], false)).toBe('Loaded skill: swiftui, edited Transcript.swift, searched “swift grid”')
    const running = [
      tool('t1', 'read_file', { args: { path: 'a.swift' } }),
      tool('t2', 'terminal', { args: { command: 'cd /repo && swift build 2>&1 | tail -20' }, phase: 'running' }),
    ]
    expect(ToolCallSummary.run(running, true)).toBe('Explored a.swift, running swift build')
    expect(ToolCallSummary.run([tool('t1', 'terminal', { phase: 'failed' }), tool('t2', 'terminal')], false)).toBe('Ran 2 commands, 1 tool call failed')
  })

  test('shell commands lose their plumbing', () => {
    expect(ToolCallSummary.summarizeShellCommand('cd /x && FOO=1 make 2>&1 | tail -5')).toBe('FOO=1 make')
    expect(ToolCallSummary.summarizeShellCommand('ls -la')).toBe('ls -la')
    expect(ToolCallSummary.summarizeShellCommand('git add . && git commit -m \'a && b\'; echo "--done--"')).toBe('git add . + 1 command')
  })

  test('stored rows carry their time', () => {
    const items = storedItems([{ id: 7, role: 'user', content: 'hi', timestamp: 1_700_000_000 }], new Map())
    expect(items[0]!.timestamp).toBe(1_700_000_000_000)
  })
})
