import { describe, expect, test } from 'vitest'
import { GatewayConnection, SessionSidebar, type GatewayConnector, type MessageTransport, type SessionsREST } from '../../src/index.ts'
import { FakeTransport, answering } from '../fake-transport.ts'

const profiles = [{ name: 'default', canonical_session: { id: 'bot' }, has_avatar: true }]
const rows = [
  { id: 'a', title: 'A', message_count: 2, source: 'desktop' },
  { id: 'b', title: 'B', message_count: 3, source: 'tui' },
]

function connector(extra: Record<string, unknown> = {}) {
  const sockets: FakeTransport[] = []
  const connector: GatewayConnector = {
    async makeTransport(): Promise<MessageTransport> {
      const socket = new FakeTransport()
      socket.respond = answering({
        'profiles.list': { profiles },
        'session.list': { sessions: rows },
        'profiles.get_asset': { found: true, data: 'data:image/png;base64,AAAA' },
        ...extra,
      })
      const connect = socket.connect.bind(socket)
      socket.connect = async () => { await connect(); queueMicrotask(() => socket.ready()) }
      sockets.push(socket)
      return socket
    },
  }
  return { connector, sockets }
}

/** A dashboard: newest messages and prompts per session, watermarks, PATCH log. */
function dashboard(state: {
  newest: Record<string, { role: string; timestamp: number }>
  prompts?: Record<string, number>
  marks?: Record<string, number>
}) {
  const requests: Array<{ method: string; path: string; query?: Record<string, string | undefined>; body?: unknown }> = []
  const rest: SessionsREST = {
    async send<T>(method: string, path: string, options: { query?: Record<string, string | undefined>; body?: unknown } = {}) {
      requests.push({ method, path, ...options })
      const id = path.split('/')[3] ?? ''
      if (path.endsWith('/messages')) {
        const message = state.newest[id]
        return { messages: message ? [message] : [], pagination: { order: 'latest' } } as T
      }
      if (path.endsWith('/timeline')) {
        const prompt = state.prompts?.[id]
        return { entries: prompt ? [{ timestamp: prompt }] : [], pagination: { has_more: false } } as T
      }
      if (path === '/api/sessions') {
        return { sessions: Object.entries(state.marks ?? {}).map(([sid, read]) => ({ id: sid, last_read_at: read })) } as T
      }
      if (path.endsWith('/mutation-snapshot')) return { exists: true, runtime_revision: 7 } as T
      if (path === '/api/sessions/search') {
        return { results: [{ session_id: 'b', snippet: '>>>hi<<<', role: 'user' }, { session_id: 'z', source: 'cron' }] } as T
      }
      return {} as T
    },
  }
  return { rest, requests }
}

async function settle(sidebar: SessionSidebar, connection: GatewayConnection) {
  await connection.settled()
  for (let index = 0; index < 20; index++) await new Promise((resolve) => setTimeout(() => resolve(undefined), 0))
  void sidebar
}

describe('SessionSidebar', () => {
  test('reads each row, orders by the last prompt, and syncs unread with the watermark', async () => {
    const { connector: server } = connector()
    const api = dashboard({
      newest: { a: { role: 'assistant', timestamp: 2000 }, b: { role: 'user', timestamp: 3000 } },
      prompts: { a: 1900, b: 3000 },
      // `a` was read on another device up to its reply.
      marks: { a: 2000, b: 0 },
    })
    const connection = new GatewayConnection()
    const sidebar = new SessionSidebar({ connection, rest: () => api.rest, serverKey: () => 'srv', now: () => 1_000_000, refreshIntervalMs: 0 })
    await sidebar.load()
    await connection.connect(server)
    await settle(sidebar, connection)
    expect(sidebar.activity('default', 'a')).toEqual({ lastPrompt: 1_900_000, newestMessage: 2_000_000, newestReply: 2_000_000 })
    expect(sidebar.ordered('default', connection.get().sessions.default!).map((row) => row.id)).toEqual(['b', 'a'])
    expect(sidebar.isUnread('default', 'a')).toBe(false)
    expect(sidebar.get().avatars).toEqual({ default: 'data:image/png;base64,AAAA' })
    sidebar.dispose()
  })

  test('a reply newer than what was seen is unread; selecting the row marks it read on the server', async () => {
    const { connector: server } = connector()
    const api = dashboard({ newest: { a: { role: 'assistant', timestamp: 2000 } }, marks: { a: 100 } })
    const connection = new GatewayConnection()
    const sidebar = new SessionSidebar({ connection, rest: () => api.rest, serverKey: () => 'srv', now: () => 1_000_000, refreshIntervalMs: 0 })
    await sidebar.load()
    await connection.connect(server)
    await settle(sidebar, connection)
    expect(sidebar.isUnread('default', 'a')).toBe(true)
    sidebar.select({ kind: 'session', profile: 'default', id: 'a' })
    await settle(sidebar, connection)
    expect(sidebar.isUnread('default', 'a')).toBe(false)
    const patch = api.requests.find((request) => request.method === 'PATCH')
    expect(patch?.path).toBe('/api/sessions/a')
    expect(patch?.body).toMatchObject({ unread: false, expected_revision: 7, profile: 'default' })
    sidebar.dispose()
  })

  test('search answers listed sources only, as list rows', async () => {
    const { connector: server } = connector()
    const api = dashboard({ newest: {} })
    const connection = new GatewayConnection()
    const sidebar = new SessionSidebar({ connection, rest: () => api.rest, serverKey: () => 'srv', refreshIntervalMs: 0 })
    await connection.connect(server)
    await settle(sidebar, connection)
    await sidebar.search('  hi ')
    expect(sidebar.get().search.query).toBe('hi')
    expect(sidebar.get().search.results.map((result) => result.row.title)).toEqual(['B'])
    const request = api.requests.find((each) => each.path === '/api/sessions/search')
    expect(request?.query).toMatchObject({ q: 'hi', profile: 'default', sources: 'desktop,tui' })
    await sidebar.search('')
    expect(sidebar.get().search.results).toEqual([])
    sidebar.dispose()
  })

  test('keeps the lists and shows them at the next launch before connecting', async () => {
    let saved: unknown
    const store = { load: async () => saved, save: (value: unknown) => { saved = value } }
    const { connector: server } = connector()
    const api = dashboard({ newest: { a: { role: 'assistant', timestamp: 2000 } } })
    const first = new GatewayConnection()
    const sidebar = new SessionSidebar({ connection: first, rest: () => api.rest, serverKey: () => 'srv', store, refreshIntervalMs: 0 })
    await sidebar.load()
    sidebar.setPinned(true, 'srv', 'default', 'b')
    await first.connect(server)
    await settle(sidebar, first)
    await new Promise((resolve) => setTimeout(() => resolve(undefined), 600))
    sidebar.dispose()

    const next = new GatewayConnection()
    const again = new SessionSidebar({ connection: next, rest: () => undefined, serverKey: () => 'srv', store, refreshIntervalMs: 0 })
    await again.load()
    expect(next.get().bots.map((bot) => bot.name)).toEqual(['default'])
    expect(next.get().sessions.default?.map((row) => row.id)).toEqual(['a', 'b'])
    expect(again.isPinned('srv', 'default', 'b')).toBe(true)
    expect(again.activity('default', 'a')?.newestReply).toBe(2_000_000)
    expect(again.get().avatars.default).toBeDefined()
    again.dispose()
  })
})
