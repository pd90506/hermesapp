import { describe, expect, test } from 'vitest'
import { DashboardConnector, DashboardRequestError, GatewayEndpoint, dashboardAPI, pathSegment, profileGet, profilePut,
  type GatewayCredential, type HttpRequest } from '../src/index.ts'

function server(credential: GatewayCredential, answer: (request: HttpRequest, n: number) => { status: number; body: string }) {
  const requests: HttpRequest[] = []
  const http = { async send(request: HttpRequest) { requests.push(request); return answer(request, requests.length) } }
  const connector = new DashboardConnector(new GatewayEndpoint('https://hermes.example.ts.net'), credential, http,
    () => { throw new Error('no sockets') })
  return { api: dashboardAPI(connector), requests }
}

describe('dashboardAPI', () => {
  test('a token goes in Authorization, the profile in the query', async () => {
    const { api, requests } = server({ kind: 'bearer', accessToken: 'tok' }, () => ({ status: 200, body: '{"ok":true}' }))
    expect(await profilePut(api, '/api/skills/toggle', 'coder', { name: 'a', enabled: true })).toEqual({ ok: true })
    expect(requests[0]).toMatchObject({
      method: 'PUT', url: 'https://hermes.example.ts.net/api/skills/toggle?profile=coder',
      body: '{"name":"a","enabled":true}',
      headers: { Authorization: 'Bearer tok', 'Content-Type': 'application/json' },
    })
  })

  test('a password sign-in logs in again once after a 401', async () => {
    const { api, requests } = server({ kind: 'password', provider: 'basic', username: 'u', password: 'p' },
      (_request, n) => (n === 1 ? { status: 401, body: '{}' } : { status: 200, body: '[]' }))
    expect(await profileGet(api, '/api/skills', 'default', [['x', '1']])).toEqual([])
    expect(requests.map((r) => r.url)).toEqual([
      'https://hermes.example.ts.net/api/skills?profile=default&x=1',
      'https://hermes.example.ts.net/auth/password-login',
      'https://hermes.example.ts.net/api/skills?profile=default&x=1',
    ])
    expect(requests[0]?.headers?.Authorization).toBeUndefined()
  })

  test('a refusal carries the dashboard\'s reason', async () => {
    const { api } = server({ kind: 'sessionToken', token: 't' }, () => ({ status: 409, body: '{"detail":"Provided by a plugin"}' }))
    const error = await api.send('PUT', '/api/mcp/servers/x/enabled').catch((e: unknown) => e)
    expect(error).toBeInstanceOf(DashboardRequestError)
    expect(error).toMatchObject({ status: 409, message: 'Provided by a plugin' })
  })

  test('path segments', () => {
    expect(pathSegment('my files')).toBe('my%20files')
    expect(pathSegment("a/b'c")).toBe('a%2Fb%27c')
  })
})
