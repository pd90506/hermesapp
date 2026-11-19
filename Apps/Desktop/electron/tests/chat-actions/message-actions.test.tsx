import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { Observable, type StoredMessage } from '@talaria/hermes-core'
import { ModelContext } from '../../src/renderer/app/hooks.ts'
import type { AppModel } from '../../src/renderer/app/model.ts'
import { ChatPane } from '../../src/renderer/features/chat/ChatPane.tsx'
import { panelTop, tickSpacing } from '../../src/renderer/features/chat/prompt-rail/PromptRail.tsx'
import { FakeMessageStore, PagedServer, eventually } from '../../../../../Packages/hermes-core/tests/support/paged-server.ts'

// jsdom lays nothing out: a viewport and a height for every row, so the virtual list draws.
class NoResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
const sizes = ['offsetHeight', 'offsetWidth', 'clientHeight', 'clientWidth'] as const
const clipboard: string[] = []
beforeAll(() => {
  Object.assign(window, { ResizeObserver: NoResizeObserver })
  for (const name of sizes) {
    Object.defineProperty(HTMLElement.prototype, name, { configurable: true, get: () => name.endsWith('Width') ? 800 : 100 })
  }
  Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async (text: string) => { clipboard.push(text) } } })
  Element.prototype.scrollTo = vi.fn() as never
})
afterEach(() => { cleanup(); clipboard.length = 0 })

const stored: StoredMessage[] = [
  { id: 1, role: 'user', content: 'First question', timestamp: 1_700_000_000 },
  { id: 2, role: 'assistant', content: 'First **answer**', timestamp: 1_700_000_010 },
  { id: 3, role: 'user', content: 'Second question', timestamp: 1_700_000_100 },
  { id: 4, role: 'assistant', content: 'Second answer', timestamp: 1_700_000_110 },
]

async function openChat() {
  const server = new PagedServer(new FakeMessageStore(stored))
  const connection = await server.connect()
  const model = Object.assign(new Observable({}), { connection }) as unknown as AppModel
  render(<ModelContext.Provider value={model}><ChatPane /></ModelContext.Provider>)
  await act(async () => { await connection.chats.openSession('default', { id: 'stored-1', title: 'Earlier' }) })
  expect(await eventually(() => screen.queryByText('Second answer') !== null)).toBe(true)
  return { server, connection }
}

const bars = () => [...document.querySelectorAll<HTMLElement>('[data-message-bar]')]

describe('message action bars', () => {
  it('every prompt and reply has one; the newest shows without hover', async () => {
    await openChat()
    expect(bars()).toHaveLength(4)
    expect(bars().map((bar) => bar.dataset.shown !== undefined)).toEqual([false, false, false, true])
    // A time per message; replies have the "…" menu, prompts don't.
    expect(document.querySelectorAll('[data-message-bar] time')).toHaveLength(4)
    expect(screen.getAllByLabelText('More actions')).toHaveLength(2)
  })

  it('Copy copies the message as Markdown', async () => {
    await openChat()
    fireEvent.click(screen.getAllByLabelText('Copy Message')[1]!)
    expect(await eventually(() => clipboard.length === 1)).toBe(true)
    expect(clipboard[0]).toBe('First **answer**')
  })

  it('right-click offers Copy Message and Copy Conversation', async () => {
    await openChat()
    fireEvent.contextMenu(screen.getByText('Second question'))
    const items = screen.getAllByRole('menuitem').map((item) => item.textContent)
    expect(items).toEqual(['Copy Message', 'Copy Conversation'])
    fireEvent.click(screen.getByRole('menuitem', { name: 'Copy Conversation' }))
    expect(await eventually(() => clipboard.length === 1)).toBe(true)
    expect(clipboard[0]).toBe('## User\n\nFirst question\n\n## Assistant\n\nFirst **answer**\n\n## User\n\nSecond question\n\n## Assistant\n\nSecond answer')
  })

  it('Branch in New Chat branches at the reply and opens the branch', async () => {
    const { server, connection } = await openChat()
    server.held.add('session.branch')
    fireEvent.click(screen.getAllByLabelText('More actions')[0]!)
    fireEvent.click(screen.getByRole('menuitem', { name: 'Branch in New Chat' }))
    expect(await eventually(() => server.heldFrames.length === 1)).toBe(true)
    const frame = server.heldFrames[0]!
    expect(frame.params).toMatchObject({ count: 2 })
    server.held.clear()
    await act(async () => {
      server.answer(frame, { session_id: 'rt-b', stored_session_id: 'branch-1' })
      await eventually(() => connection.chats.active?.storedSessionID === 'branch-1')
    })
    expect(connection.chats.active?.storedSessionID).toBe('branch-1')
  })
})

describe('the prompt rail', () => {
  it('has a tick per prompt, and its panel lists them on hover', async () => {
    await openChat()
    const ticks = screen.getByRole('navigation', { name: 'Prompts' })
    expect([...ticks.querySelectorAll('button')].map((tick) => tick.getAttribute('aria-label')))
      .toEqual(['First question', 'Second question'])
    fireEvent.mouseEnter(ticks)
    expect(screen.getAllByRole('listitem').map((row) => row.textContent)).toEqual(['First question', 'Second question'])
  })

  it('packs ticks into a short rail and opens the panel level with them', () => {
    expect(tickSpacing(3, 400)).toBe(14)
    expect(tickSpacing(100, 400)).toBe(4)
    expect(panelTop(3, 400)).toBe((400 - 42) / 2)
    expect(panelTop(100, 400)).toBe(0)
  })
})
