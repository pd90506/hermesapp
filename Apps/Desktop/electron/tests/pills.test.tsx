import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { AlertGate, Observable, defaultAlertPreferences, type GatewayAlert } from '@talaria/hermes-core'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel } from '../src/renderer/app/model.ts'
import { ChatPane } from '../src/renderer/features/chat/ChatPane.tsx'
import { elapsed } from '../src/renderer/features/chat/pills/SubagentsPill.tsx'
import { Notifier, notificationTitle } from '../src/renderer/features/notifications/notifier.ts'
import { PagedServer, eventually } from '../../../../Packages/hermes-core/tests/support/paged-server.ts'

class NoResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
const sizes = ['offsetHeight', 'offsetWidth', 'clientHeight', 'clientWidth'] as const
beforeAll(() => {
  Object.assign(window, { ResizeObserver: NoResizeObserver })
  for (const name of sizes) {
    Object.defineProperty(HTMLElement.prototype, name, { configurable: true, get: () => name.endsWith('Width') ? 800 : 100 })
  }
})
afterEach(cleanup)

/** The Bot Chat on screen, on a gateway that also answers the background methods. */
async function openChat(extra: Record<string, (params: Record<string, unknown>) => unknown> = {}) {
  const server = new PagedServer()
  const connection = await server.connect()
  const base = server.socket.respond!
  server.socket.respond = (frame) => {
    const answer = extra[frame.method as string]
    if (frame.id !== undefined && answer) return { jsonrpc: '2.0', id: frame.id, result: answer((frame.params ?? {}) as Record<string, unknown>) }
    return base(frame)
  }
  const model = Object.assign(new Observable({}), { connection }) as unknown as AppModel
  render(<ModelContext.Provider value={model}><ChatPane /></ModelContext.Provider>)
  const chat = await act(async () => connection.chats.openBotChat('coder'))
  return { server, connection, chat }
}

describe('the pills over the composer', () => {
  it('shows the task list from the newest Todo call and opens it into a card', async () => {
    const { server, chat } = await openChat()
    const todos = { todos: [{ id: '1', content: 'Read the code', status: 'completed' }, { id: '2', content: 'Write the test', status: 'in_progress' }], revision: 1 }
    act(() => {
      server.event('message.start', chat.sessionID, 1, {})
      server.event('tool.start', chat.sessionID, 2, { tool_id: 't1', name: 'todo' })
      server.event('tool.complete', chat.sessionID, 3, { tool_id: 't1', name: 'todo', result: todos })
    })
    expect(await eventually(() => screen.queryByTestId('todoPill') !== null)).toBe(true)
    expect(screen.getByTestId('todoPill').textContent).toContain('1/2 tasks')
    fireEvent.click(screen.getByTestId('todoPill'))
    expect(screen.getByTestId('todoPanel').textContent).toContain('Write the test')
    expect(screen.getByLabelText('Read the code, Done')).toBeTruthy()
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByTestId('todoPanel')).toBeNull()
  })

  it('lists background tasks with Stop, and only one card is open at a time', async () => {
    const { server, chat } = await openChat({
      'process.list': () => ({ processes: [{ session_id: 'p1', status: 'running', command: 'npm run build' }] }),
      'process.kill': () => ({ status: 'killed' }),
      'subagent.list': () => ({ subagents: [{ subagent_id: 'a', goal: 'Check the docs', status: 'running', started_at: Date.now() / 1000 }] }),
    })
    expect(await eventually(() => screen.queryByTestId('backgroundProcessesPill') !== null)).toBe(true)
    expect(await eventually(() => screen.queryByTestId('subagentsPill') !== null)).toBe(true)
    expect(screen.getByTestId('backgroundProcessesPill').textContent).toContain('1 background task')
    expect(screen.getByTestId('subagentsPill').textContent).toContain('1 subagent')
    fireEvent.click(screen.getByTestId('backgroundProcessesPill'))
    expect(screen.getByTestId('backgroundProcessesPanel').textContent).toContain('npm run build')
    fireEvent.click(screen.getByTestId('subagentsPill'))
    expect(screen.queryByTestId('backgroundProcessesPanel')).toBeNull()
    fireEvent.click(screen.getByTestId('subagentRow'))
    expect(screen.getByTestId('subagentSteerField')).toBeTruthy()
    fireEvent.click(screen.getByTestId('backgroundProcessesPill'))
    fireEvent.click(screen.getByTestId('backgroundProcessStop'))
    expect(await eventually(() => server.calls('process.kill').length === 1)).toBe(true)
    expect(server.calls('process.kill')[0]).toMatchObject({ session_id: chat.sessionID, process_id: 'p1' })
    expect(await eventually(() => screen.queryByTestId('backgroundProcessesPill') === null)).toBe(true)
  })

  it('counts a subagent’s time as minutes and seconds', () => {
    expect(elapsed(65_000)).toBe('1:05')
    expect(elapsed(3_725_000)).toBe('1:02:05')
  })
})

describe('notifications', () => {
  const alert = (change: Partial<GatewayAlert> = {}): GatewayAlert => ({
    kind: 'turnDone', title: 'Hermes finished', subtitle: 'Fix the flaky test', body: 'Done.', sessionID: 'rt-1',
    storedSessionID: 's1', profile: 'coder', isBotChat: false, isActiveChat: true, isOnScreen: true, ...change,
  })

  function notifier(focused: boolean) {
    const shown: unknown[] = []
    const model = Object.assign(new Observable({ alertPreferences: defaultAlertPreferences }), {
      servers: new Observable({ servers: [] }),
      bridge: { notifications: { show: vi.fn(async (n: unknown) => { shown.push(n); return true }) } },
    }) as unknown as AppModel
    const document = { hidden: false, hasFocus: () => focused } as unknown as Document
    return { notifier: new Notifier(model, document), shown }
  }

  it('names the chat in the title and carries what a click opens', () => {
    const { notifier: away, shown } = notifier(false)
    expect(away.show(alert(), 'server-1')).toBe(true)
    expect(shown[0]).toMatchObject({
      title: 'Hermes finished — Fix the flaky test', body: 'Done.',
      target: { serverID: 'server-1', profile: 'coder', storedSessionID: 's1', isBotChat: false },
    })
    expect(notificationTitle(alert({ subtitle: undefined }))).toBe('Hermes finished')
  })

  it('stays quiet for the chat on screen while the window has focus', () => {
    const { notifier: front, shown } = notifier(true)
    expect(front.show(alert(), 'server-1')).toBe(false)
    expect(front.show(alert({ kind: 'approval', isOnScreen: false, requestID: 'r1' }), 'server-1')).toBe(true)
    expect(shown[0]).toMatchObject({ target: { requestID: 'r1' } })
    expect(front.gate).toBeInstanceOf(AlertGate)
  })
})
