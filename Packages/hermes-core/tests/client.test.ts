import { afterEach, describe, expect, test, vi } from 'vitest'
import { GatewayClient, GatewayClientError, RPCError, type Inbound } from '../src/index.ts'
import { FakeTransport, answering } from './fake-transport.ts'

afterEach(() => vi.useRealTimers())

async function connected(transport = new FakeTransport(), options = {}) {
  transport.respond ??= answering({})
  const client = new GatewayClient(transport, options)
  const inbound: Inbound[] = []
  client.subscribe((item) => inbound.push(item))
  const connecting = client.connect()
  transport.ready()
  await connecting
  return { client, transport, inbound }
}

describe('GatewayClient', () => {
  test('waits for gateway.ready, then advertises server requests', async () => {
    const { client, transport } = await connected()
    expect(client.ready?.replay_epoch).toBe('e1')
    expect(transport.sent[0]).toMatchObject({ method: 'client.capabilities', params: { server_requests: true }, id: 'r1' })
    expect(client.isConnected).toBe(true)
  })

  test('fails when the gateway never says ready', async () => {
    vi.useFakeTimers()
    const transport = new FakeTransport()
    const client = new GatewayClient(transport, { readyTimeoutMs: 1000 })
    const connecting = client.connect()
    const failure = expect(connecting).rejects.toMatchObject({ kind: 'readyTimeout' })
    await vi.advanceTimersByTimeAsync(1001)
    await failure
    expect(transport.closed).toBe(true)
  })

  test('correlates responses with calls, and errors become RPCError', async () => {
    const transport = new FakeTransport()
    transport.respond = (frame) => {
      if (frame.method === 'client.capabilities') return { jsonrpc: '2.0', id: frame.id, result: {} }
      if (frame.method === 'good') return { jsonrpc: '2.0', id: frame.id, result: { ok: 1 } }
      if (frame.method === 'bad') return { jsonrpc: '2.0', id: frame.id, error: { code: 4001, message: 'session not found' } }
      return undefined
    }
    const { client } = await connected(transport)
    const [good, bad] = await Promise.allSettled([client.call('good', {}), client.call('bad', {})])
    expect(good).toEqual({ status: 'fulfilled', value: { ok: 1 } })
    expect(bad.status).toBe('rejected')
    const error = (bad as PromiseRejectedResult).reason
    expect(error).toBeInstanceOf(RPCError)
    expect(error.code).toBe(4001)
    expect(error.message).toBe('session not found')
  })

  test('a call times out', async () => {
    const { client } = await connected()
    vi.useFakeTimers()
    const call = client.call('never', {}, 500)
    const failure = expect(call).rejects.toMatchObject({ kind: 'timeout' })
    await vi.advanceTimersByTimeAsync(501)
    await failure
  })

  test('declines unsupported server requests: 4404 for bridges, -32601 for the rest', async () => {
    const { transport, inbound } = await connected(undefined, { supportedServerRequests: new Set(['approval']) })
    transport.push({ jsonrpc: '2.0', id: 's1', method: 'preview.read', params: {} })
    transport.push({ jsonrpc: '2.0', id: 's2', method: 'mystery', params: {} })
    transport.push({ jsonrpc: '2.0', id: 's3', method: 'approval', params: { command: 'rm' } })
    transport.push({ jsonrpc: '2.0', id: 's3', method: 'approval', params: { command: 'rm' } })
    await Promise.resolve()
    const answers = transport.sent.filter((frame) => frame.error)
    expect(answers).toEqual([
      { jsonrpc: '2.0', id: 's1', error: { code: 4404, message: 'not shown in this client' } },
      { jsonrpc: '2.0', id: 's2', error: { code: -32601, message: 'unsupported by client: mystery' } },
    ])
    const requests = inbound.filter((item) => item.kind === 'serverRequest')
    expect(requests).toHaveLength(1)
  })

  test('drops events whose seq was already seen', async () => {
    const { transport, inbound } = await connected()
    for (const seq of [1, 2, 2, 1, 3]) {
      transport.push({ jsonrpc: '2.0', method: 'event', params: { type: 'message.delta', session_id: 'a', seq, payload: { text: 'x' } } })
    }
    transport.push({ jsonrpc: '2.0', method: 'event', params: { type: 'sessions.changed' } })
    const seqs = inbound.flatMap((item) =>
      item.kind === 'event' && item.event.type !== 'gateway.ready' ? [item.event.seq ?? 'global'] : [])
    expect(seqs).toEqual([1, 2, 3, 'global'])
  })

  test('a dropped socket fails pending calls and tells subscribers', async () => {
    const { client, transport, inbound } = await connected()
    const call = client.call('never', {})
    transport.drop()
    await expect(call).rejects.toBeInstanceOf(GatewayClientError)
    expect(inbound.at(-1)).toMatchObject({ kind: 'disconnected' })
    expect((inbound.at(-1) as { error?: Error }).error).toBeDefined()
    await expect(client.call('again', {})).rejects.toMatchObject({ kind: 'notConnected' })
  })

  test('a deliberate close ends without an error', async () => {
    const { client, transport, inbound } = await connected()
    await client.close()
    expect(transport.closed).toBe(true)
    expect(inbound.at(-1)).toEqual({ kind: 'disconnected' })
  })

  test('heartbeats, and a silent gateway is dropped', async () => {
    vi.useFakeTimers()
    const transport = new FakeTransport()
    transport.respond = answering({})
    const client = new GatewayClient(transport, { heartbeatIntervalMs: 1000, heartbeatTimeoutMs: 2500 })
    const inbound: Inbound[] = []
    client.subscribe((item) => inbound.push(item))
    const connecting = client.connect()
    transport.ready('e1', true)
    await vi.advanceTimersByTimeAsync(0)
    await connecting
    await vi.advanceTimersByTimeAsync(1000)
    expect(transport.methods()).toContain('gateway.ping')
    await vi.advanceTimersByTimeAsync(3000)
    expect(inbound.at(-1)).toMatchObject({ kind: 'disconnected', error: { kind: 'heartbeatTimeout' } })
  })
})
