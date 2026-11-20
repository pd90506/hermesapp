import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { Observable } from '@talaria/hermes-core'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel } from '../src/renderer/app/model.ts'
import { ChatPane } from '../src/renderer/features/chat/ChatPane.tsx'
import { composerKeyAction, type ComposerKey } from '../src/renderer/features/composer/keys.ts'
import { PagedServer, completePayload, eventually, rows } from '../../../../Packages/hermes-core/tests/support/paged-server.ts'

const key = (change: Partial<ComposerKey>): ComposerKey =>
  ({ key: 'Enter', shiftKey: false, altKey: false, metaKey: false, ctrlKey: false, isComposing: false, ...change })

describe('composerKeyAction', () => {
  it('sends on Return, ⌘↩ and Ctrl+Enter', () => {
    expect(composerKeyAction(key({}))).toBe('send')
    expect(composerKeyAction(key({ metaKey: true }))).toBe('send')
    expect(composerKeyAction(key({ ctrlKey: true }))).toBe('send')
  })

  it('breaks the line on Shift- and Option/Alt-Return', () => {
    expect(composerKeyAction(key({ shiftKey: true }))).toBe('newline')
    expect(composerKeyAction(key({ altKey: true }))).toBe('newline')
  })

  it('leaves Return to an input method while it composes', () => {
    expect(composerKeyAction(key({ isComposing: true }))).toBe('none')
    expect(composerKeyAction(key({ isComposing: true, metaKey: true }))).toBe('none')
    expect(composerKeyAction(key({ key: 'a' }))).toBe('none')
  })
})

// jsdom lays nothing out: give the transcript a viewport and every row a height, so the
// virtual list draws its rows.
class NoResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
// Each test file runs in its own jsdom, so these stay in this file.
const sizes = ['offsetHeight', 'offsetWidth', 'clientHeight', 'clientWidth'] as const
beforeAll(() => {
  Object.assign(window, { ResizeObserver: NoResizeObserver })
  for (const name of sizes) {
    Object.defineProperty(HTMLElement.prototype, name, { configurable: true, get: () => name.endsWith('Width') ? 800 : 100 })
  }
})
afterEach(cleanup)

async function openPane(server: PagedServer) {
  const connection = await server.connect()
  const model = Object.assign(new Observable({}), { connection }) as unknown as AppModel
  render(<ModelContext.Provider value={model}><ChatPane /></ModelContext.Provider>)
  return connection
}

describe('ChatPane', () => {
  it('asks for a chat when none is open', async () => {
    await openPane(new PagedServer())
    expect(screen.getByText('No Chat Selected')).toBeTruthy()
  })

  it('opens the Bot Chat, sends with Return and shows the reply', async () => {
    const server = new PagedServer()
    server.store.append(rows(1, 4))
    const connection = await openPane(server)
    await act(async () => { await connection.chats.openBotChat('coder') })
    expect(await eventually(() => screen.queryByText('row 4') !== null)).toBe(true)

    const text = screen.getByLabelText('Message') as HTMLTextAreaElement
    fireEvent.change(text, { target: { value: 'hello there' } })
    fireEvent.keyDown(text, { key: 'Enter' })
    expect(await eventually(() => server.calls('prompt.submit').length === 1)).toBe(true)
    expect(server.calls('prompt.submit')[0]?.text).toBe('hello there')
    expect(await eventually(() => screen.queryByText('hello there') !== null)).toBe(true)
    expect(text.value).toBe('')

    const sid = String(server.calls('prompt.submit')[0]?.session_id)
    const reply = server.store.nextID()
    act(() => {
      server.store.append([{ id: reply, role: 'assistant', content: 'General Kenobi', timestamp: 1_700_000_100 }])
      server.event('message.complete', sid, 1, completePayload('General Kenobi', [reply - 1, reply]))
    })
    expect(await eventually(() => screen.queryByText('General Kenobi') !== null)).toBe(true)
  })

  it('keeps a draft per chat', async () => {
    const server = new PagedServer()
    const connection = await openPane(server)
    await act(async () => { await connection.chats.openBotChat('coder') })
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'half a thought' } })
    await act(async () => { await connection.chats.newChat('default') })
    expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('')
    await act(async () => { await connection.chats.openBotChat('coder') })
    expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('half a thought')
  })

  it('titles the chat on screen and follows its renames', async () => {
    const server = new PagedServer()
    const connection = await openPane(server)
    await act(async () => { await connection.chats.openBotChat('coder') })
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Coder')
    await act(async () => { await connection.chats.newChat('default') })
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Side chat · Hermes')
    act(() => { connection.chats.get().active?.setTitle('Plan the trip') })
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Plan the trip · Hermes')
  })
})
