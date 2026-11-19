import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import {
  Observable, blockKind, makeItem, reviewDisplayKind, transcriptBlocks,
  type ChatSession, type JSONValue, type ToolPhase, type TranscriptBlock, type TranscriptItem,
} from '@talaria/hermes-core'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel } from '../src/renderer/app/model.ts'
import { blockRenderer } from '../src/renderer/features/chat/blocks/registry.ts'
import '../src/renderer/features/chat/blocks/registered-blocks.ts'

class NoResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
beforeAll(() => { Object.assign(window, { ResizeObserver: NoResizeObserver }) })
afterEach(cleanup)

const user = (id: string, text = 'question', at?: number): TranscriptItem =>
  ({ ...makeItem(id, 'user', text), ...(at !== undefined ? { timestamp: at } : {}) })
const reply = (id: string, text: string, options: { reasoning?: string; interim?: boolean; at?: number } = {}): TranscriptItem => ({
  ...makeItem(id, 'assistant', text), reasoning: options.reasoning ?? '', isInterim: options.interim ?? false,
  ...(options.at !== undefined ? { timestamp: options.at } : {}),
})
function tool(id: string, name: string, options: { args?: JSONValue; result?: JSONValue; phase?: ToolPhase; inlineDiff?: string } = {}): TranscriptItem {
  const phase = options.phase ?? 'complete'
  return {
    ...makeItem(id, 'tool', '', phase === 'running'), toolName: name,
    tool: {
      toolID: id, name, phase,
      ...(options.args !== undefined ? { args: options.args } : {}),
      ...(options.result !== undefined ? { result: options.result } : {}),
      ...(options.inlineDiff !== undefined ? { inlineDiff: options.inlineDiff } : {}),
    },
  }
}

function chat(): ChatSession {
  return new Observable({ info: { cwd: '/home/u/repo' } }) as unknown as ChatSession
}

function draw(blocks: readonly TranscriptBlock[], session = chat()) {
  // The message actions (G) wrap the rows and read the app model.
  const model = Object.assign(new Observable({}), { connection: {} }) as unknown as AppModel
  return render(
    <ModelContext.Provider value={model}>
      {blocks.map((block) => {
        const Renderer = blockRenderer(blockKind(block))!
        return <Renderer key={block.id} block={block} chat={session} isNewest={false} />
      })}
    </ModelContext.Provider>,
  )
}

const turn = [
  user('u1', 'question', 100_000),
  reply('a1', 'Let me look.', { interim: true, reasoning: 'Plan the search.', at: 101_000 }),
  tool('t1', 'terminal', { args: { command: 'git status', workdir: '/repo/app' }, result: { output: 'On branch main', exit_code: 0 } }),
  tool('t2', 'read_file', { args: { path: 'a.md' }, result: { content: '1|# A' } }),
  reply('a2', 'All good.', { at: 145_000 }),
]

describe('a turn’s work', () => {
  it('folds to its line, then opens to its groups, steps and cards', () => {
    draw(transcriptBlocks(turn, false))
    const line = screen.getByRole('button', { name: /Completed in 45s/ })
    expect(line.getAttribute('aria-expanded')).toBe('false')
    expect(screen.getByText('All good.')).toBeTruthy()
    expect(screen.queryByText('Let me look.')).toBeNull()

    const bars = screen.getAllByRole('button', { name: 'Copy Message' }).length
    fireEvent.click(line)
    expect(screen.getByText('Let me look.')).toBeTruthy()
    // The commentary inside the work has no action bar; the prompt and the answer keep theirs.
    expect(bars).toBe(2)
    expect(screen.getAllByRole('button', { name: 'Copy Message' })).toHaveLength(bars)
    const group = screen.getByRole('button', { name: /Ran commands, read files/ })
    expect(screen.queryByTestId('work-step')).toBeNull()

    fireEvent.click(group)
    expect(screen.getAllByTestId('work-step').map((step) => step.textContent)).toEqual([
      'Think·Plan the search.', 'Bash·git status', 'Read·a.md',
    ])
    fireEvent.click(screen.getByRole('button', { name: /Bash·git status/ }))
    const card = screen.getByTestId('work-step-card')
    expect(card.textContent).toContain('app')
    expect(card.textContent).toContain('git status')
    expect(card.textContent).toContain('On branch main')
    expect(card.textContent).toContain('Copy')
  })

  it('opens one layer while the turn works and counts the time', () => {
    const live = [user('u1', 'q', Date.now() - 12_000), tool('t1', 'terminal', { args: { command: 'make' }, phase: 'running' })]
    draw(transcriptBlocks(live, true))
    const line = screen.getByRole('button', { name: /Working… 1\ds/ })
    expect(line.getAttribute('aria-expanded')).toBe('true')
    // The live group's line is its newest step's.
    expect(screen.getByTestId('step-group').textContent).toContain('Bash·make')
  })

  it('remembers a fold the user opened when its row is built again', () => {
    const session = chat()
    const blocks = transcriptBlocks(turn, false)
    draw(blocks, session)
    fireEvent.click(screen.getByRole('button', { name: /Completed in 45s/ }))
    cleanup()
    draw(blocks, session)
    expect(screen.getByRole('button', { name: /Completed in 45s/ }).getAttribute('aria-expanded')).toBe('true')
  })
})

describe('tool rows', () => {
  it('a card call opens to its detail; a settled edit without a diff draws nothing', () => {
    const items = [
      tool('d1', 'delegate_task', { args: { context: 'Research two topics' }, result: { message: 'Two tasks finished', count: 2 } }),
      tool('e1', 'write_file', { args: { path: 'B.md' }, result: { bytes_written: 3 } }),
    ]
    draw(items.map((item) => ({ kind: 'item', id: item.id, item })))
    expect(screen.getAllByTestId('tool-call')).toHaveLength(1)
    const line = screen.getByRole('button', { name: /Delegate Task/ })
    fireEvent.click(line)
    expect(screen.getByTestId('tool-call').textContent).toContain('Research two topics')
  })

  it('an edit with a diff opens to it, in its colours', () => {
    const edit = tool('e1', 'patch', { args: { path: 'Sources/A.swift' }, result: { success: true }, inlineDiff: '--- a/A\n+++ b/A\n-old\n+new' })
    draw([{ kind: 'item', id: 'e1', item: edit }])
    expect(screen.getByRole('button', { name: /A\.swift/ }).getAttribute('aria-expanded')).toBe('true')
    expect(document.querySelector('[data-line="added"]')?.textContent).toBe('+new')
    expect(document.querySelector('[data-line="removed"]')?.textContent).toBe('-old')
  })
})

describe('notice lines', () => {
  it('a background notice is one line that opens to its output', () => {
    const notice = user('n1', '[IMPORTANT: Background process proc_1 completed normally (exit code 0).\nCommand: make\nOutput:\ndone]')
    draw(transcriptBlocks([notice], false))
    const line = screen.getByRole('button', { name: /Background process proc_1 completed/ })
    fireEvent.click(line)
    expect(screen.getByTestId('background-notice').textContent).toContain('Command: make')
  })

  it('a review line shows its label and detail', () => {
    const review = { ...makeItem('r1', 'system', '💾 Self-improvement review: Memory updated'), displayKind: reviewDisplayKind }
    draw(transcriptBlocks([review], false))
    const row = screen.getByTestId('review-note')
    expect(row.textContent).toBe('Self-improvement reviewMemory updated')
  })
})
