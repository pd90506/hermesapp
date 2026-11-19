import { afterEach, describe, expect, test, vi } from 'vitest'
import { DashboardError, GatewayConnection, exponentialBackoff, type GatewayConnector, type MessageTransport } from '../src/index.ts'
import bots from '../../fixtures/bots.json' with { type: 'json' }
import { FakeTransport, answering } from './fake-transport.ts'

afterEach(() => vi.useRealTimers())

function row(id: string, source = 'desktop') {
  return { id, title: id, preview: '', started_at: 1, message_count: 1, source }
}

/** A connector whose sockets answer profiles.list and session.list. */
function server(sessionsFor: (params: { limit: number; profile: string }) => unknown[]) {
  const sockets: FakeTransport[] = []
  const listCalls: Array<{ limit: number; profile: string }> = []
  let failNext: Error | undefined
  const connector: GatewayConnector = {
    async makeTransport(): Promise<MessageTransport> {
      if (failNext) { const error = failNext; failNext = undefined; throw error }
      const socket = new FakeTransport()
      socket.respond = answering({
        'profiles.list': { profiles: bots.profiles },
        'session.list': (params: { limit: number; profile: string }) => {
          listCalls.push(params)
          return { sessions: sessionsFor(params) }
        },
      })
      const connect = socket.connect.bind(socket)
      socket.connect = async () => {
        await connect()
        queueMicrotask(() => socket.ready())
      }
      sockets.push(socket)
      return socket
    },
  }
  return { connector, sockets, listCalls, failWith: (error: Error) => { failNext = error } }
}

describe('GatewayConnection', () => {
  test('connects, lists the bots and the default profile\'s sessions', async () => {
    const fake = server(() => [row('a'), row('cron-run', 'cron'), row('b', 'tui')])
    const connection = new GatewayConnection()
    await connection.connect(fake.connector)
    await connection.settled()
    const snapshot = connection.get()
    expect(snapshot.link).toEqual({ phase: 'connected' })
    expect(snapshot.bots.map((bot) => bot.name)).toEqual(['default', 'writer', 'research_team--b', 'ops'])
    expect(snapshot.selectedProfile).toBe('default')
    expect(snapshot.sessions.default?.map((s) => s.id)).toEqual(['a', 'b'])
    // A short first answer is read again with a doubled limit; then the limit has settled.
    expect(fake.listCalls).toEqual([{ limit: 200, profile: 'default' }, { limit: 400, profile: 'default' }])
  })

  test('a full window doubles the limit until a short answer stops growing', async () => {
    const fake = server(({ limit }) => Array.from({ length: Math.min(limit, 500) }, (_, i) => row(`s${i}`)))
    const connection = new GatewayConnection()
    await connection.connect(fake.connector)
    await connection.settled()
    expect(fake.listCalls.map((c) => c.limit)).toEqual([200, 400, 800, 1600])
    expect(connection.get().sessions.default).toHaveLength(500)
    // Later reads start at the limit that settled.
    fake.listCalls.length = 0
    await connection.refreshSessionList()
    expect(fake.listCalls.map((c) => c.limit)).toEqual([1600])
  })

  test('selecting a profile reads its sessions', async () => {
    const fake = server(({ profile }) => [row(`${profile}-1`)])
    const connection = new GatewayConnection()
    await connection.connect(fake.connector)
    await connection.settled()
    connection.selectProfile('writer')
    await vi.waitFor(() => expect(connection.get().sessions.writer?.map((s) => s.id)).toEqual(['writer-1']))
    expect(connection.get().selectedProfile).toBe('writer')
  })

  test('sessions.changed refreshes the lists', async () => {
    let n = 0
    const fake = server(() => [row(`v${n}`)])
    const connection = new GatewayConnection()
    await connection.connect(fake.connector)
    await connection.settled()
    n = 1
    fake.sockets[0]!.push({ jsonrpc: '2.0', method: 'event', params: { type: 'sessions.changed' } })
    await vi.waitFor(() => expect(connection.get().sessions.default?.[0]?.id).toBe('v1'))
  })

  test('a dropped socket reconnects with a new transport', async () => {
    const fake = server(() => [row('a')])
    const connection = new GatewayConnection({ backoff: () => 5 })
    await connection.connect(fake.connector)
    await connection.settled()
    fake.sockets[0]!.drop()
    expect(connection.get().link).toEqual({ phase: 'reconnecting', attempt: 1 })
    await vi.waitFor(() => expect(connection.get().link).toEqual({ phase: 'connected' }))
    expect(fake.sockets).toHaveLength(2)
  })

  test('a rejected sign-in stops reconnecting', async () => {
    const fake = server(() => [])
    const connection = new GatewayConnection({ backoff: () => 5 })
    await connection.connect(fake.connector)
    fake.failWith(new DashboardError('invalidCredentials', 401))
    fake.sockets[0]!.drop()
    await vi.waitFor(() => expect(connection.get().link).toEqual({ phase: 'failed', message: 'Username or password was rejected.' }))
  })

  test('a failed first connect reports it', async () => {
    const fake = server(() => [])
    fake.failWith(new DashboardError('http', 502))
    const connection = new GatewayConnection()
    await expect(connection.connect(fake.connector)).rejects.toBeInstanceOf(DashboardError)
    expect(connection.get().link).toEqual({ phase: 'failed', message: 'The dashboard answered HTTP 502.' })
  })

  test('shows trying only after the notice delay', async () => {
    vi.useFakeTimers()
    const connection = new GatewayConnection({ tryingNoticeDelayMs: 5000 })
    const never: GatewayConnector = { makeTransport: () => new Promise(() => {}) }
    void connection.connect(never)
    await vi.advanceTimersByTimeAsync(4999)
    expect(connection.get().isTryingNoticeably).toBe(false)
    await vi.advanceTimersByTimeAsync(2)
    expect(connection.get().isTryingNoticeably).toBe(true)
  })

  test('disconnect forgets everything', async () => {
    const fake = server(() => [row('a')])
    const connection = new GatewayConnection()
    await connection.connect(fake.connector)
    await connection.settled()
    await connection.disconnect()
    expect(connection.get()).toMatchObject({ link: { phase: 'disconnected' }, bots: [], sessions: {} })
    expect(fake.sockets[0]!.closed).toBe(true)
  })
})

test('backoff: 0.5 s doubling to 30 s, with 20 % jitter', () => {
  expect(exponentialBackoff(1, () => 0.5)).toBe(500)
  expect(exponentialBackoff(3, () => 0.5)).toBe(2000)
  expect(exponentialBackoff(20, () => 0.5)).toBe(30000)
  expect(exponentialBackoff(1, () => 0)).toBe(400)
  expect(exponentialBackoff(1, () => 1)).toBe(600)
})
