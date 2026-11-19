import { describe, expect, test } from 'vitest'
import { DashboardConnector, DashboardError, GatewayEndpoint, type HttpClient, type HttpRequest } from '../src/index.ts'
import { FakeTransport } from './fake-transport.ts'

/** Answers requests in order from a script. */
function scriptedHttp(answers: Array<{ status: number; body: unknown }>) {
  const requests: HttpRequest[] = []
  const http: HttpClient = {
    async send(request) {
      requests.push(request)
      const answer = answers.shift()
      if (!answer) throw new Error(`unexpected ${request.method} ${request.url}`)
      return { status: answer.status, body: JSON.stringify(answer.body) }
    },
  }
  return { http, requests }
}

const endpoint = new GatewayEndpoint('https://hermes.example.ts.net')
const socketURLs: string[] = []
const openSocket = (url: string) => {
  socketURLs.push(url)
  return new FakeTransport()
}

describe('DashboardConnector', () => {
  test('password: reuses the cookie session, signs in after a 401', async () => {
    const { http, requests } = scriptedHttp([
      { status: 401, body: { reason: 'session_expired' } },
      { status: 200, body: { ok: true } },
      { status: 200, body: { ticket: 'T1', ttl_seconds: 30 } },
    ])
    const connector = new DashboardConnector(endpoint,
      { kind: 'password', provider: 'basic', username: 'me', password: 'pw' }, http, openSocket)
    expect(await connector.webSocketURL()).toBe('wss://hermes.example.ts.net/api/ws?ticket=T1')
    expect(requests.map((r) => `${r.method} ${new URL(r.url).pathname}`)).toEqual([
      'POST /api/auth/ws-ticket', 'POST /auth/password-login', 'POST /api/auth/ws-ticket',
    ])
    expect(JSON.parse(requests[1]!.body!)).toEqual({ provider: 'basic', username: 'me', password: 'pw', next: '' })
  })

  test('password: a rejected password says so', async () => {
    const { http } = scriptedHttp([{ status: 401, body: {} }, { status: 401, body: {} }])
    const connector = new DashboardConnector(endpoint,
      { kind: 'password', provider: 'basic', username: 'me', password: 'bad' }, http, openSocket)
    await expect(connector.webSocketURL()).rejects.toMatchObject({ kind: 'invalidCredentials' })
  })

  test('bearer: mints the ticket with the access token', async () => {
    const { http, requests } = scriptedHttp([{ status: 200, body: { ticket: 'T2' } }])
    const connector = new DashboardConnector(endpoint, { kind: 'bearer', accessToken: 'AT' }, http, openSocket)
    await connector.makeTransport()
    expect(requests[0]!.headers).toMatchObject({ Authorization: 'Bearer AT' })
    expect(socketURLs.at(-1)).toBe('wss://hermes.example.ts.net/api/ws?ticket=T2')
  })

  test('session token: goes in the URL, no HTTP', async () => {
    const { http, requests } = scriptedHttp([])
    const connector = new DashboardConnector(new GatewayEndpoint('127.0.0.1:9119'), { kind: 'sessionToken', token: 'S' }, http, openSocket)
    expect(await connector.webSocketURL()).toBe('ws://127.0.0.1:9119/api/ws?token=S')
    expect(requests).toEqual([])
  })

  test('HTTP errors keep their kind', async () => {
    const { http } = scriptedHttp([{ status: 429, body: {} }])
    const connector = new DashboardConnector(endpoint, { kind: 'bearer', accessToken: 'AT' }, http, openSocket)
    const error = await connector.webSocketURL().catch((e) => e)
    expect(error).toBeInstanceOf(DashboardError)
    expect(error.kind).toBe('rateLimited')
  })
})
