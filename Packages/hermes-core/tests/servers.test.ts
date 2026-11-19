import { describe, expect, test } from 'vitest'
import serversAuth from '../../fixtures/servers-auth.json' with { type: 'json' }
import {
  DashboardConnector, DashboardError, GatewayConnection, GatewayEndpoint, NativeSignIn, NativeTokenSession,
  ServerRegistry, decodeAlertPreferences, hermesCandidates, isAlertOn, isNativeCallback, loadServerList,
  localBackendLaunch, makePKCE, nativeTokensFromSecret, nativeTokensSecret, readyPort, serverDisplayName,
  setAlertOn, setSourceHidden, showsSource, defaultAlertPreferences,
  type HttpClient, type HttpRequest, type ServerHost,
} from '../src/index.ts'
import { FakeTransport } from './fake-transport.ts'

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
const path = (request: HttpRequest) => `${request.method} ${new URL(request.url).pathname}`

describe('servers-auth.json', () => {
  test.each(serversAuth.pkce)('PKCE challenge of "$verifier"', (item) => {
    expect(makePKCE(item.verifier).challenge).toBe(item.challenge)
  })
  test.each(serversAuth.readyPort)('ready port in $output', (item) => {
    expect(readyPort(item.output) ?? null).toBe(item.port)
  })
})

describe('server list', () => {
  let n = 0
  const makeID = () => `id-${++n}`

  test('the first version\u2019s single server becomes the list', () => {
    const loaded = loadServerList({ server: { serverURL: 'https://hermes.example.ts.net', authMode: 'accessToken', provider: '', username: '' } }, makeID)
    expect(loaded.servers).toHaveLength(1)
    expect(loaded.migrated?.authMode).toBe('accessToken')
  })

  test('a saved list wins, even empty; bad rows are dropped and missing fields defaulted', () => {
    expect(loadServerList({ servers: [], server: { serverURL: 'x' } }, makeID).servers).toEqual([])
    const loaded = loadServerList({ servers: [{ id: 'a', serverURL: 'h:1', authMode: 'nonsense' }, 7] }, makeID)
    expect(loaded.servers).toEqual([{ id: 'a', name: '', serverURL: 'h:1', authMode: 'password', provider: 'basic', username: '' }])
  })

  test('display names', () => {
    expect(serverDisplayName({ name: ' Home ', serverURL: '' })).toBe('Home')
    expect(serverDisplayName({ name: '', serverURL: 'https://hermes.example.ts.net' })).toBe('hermes')
    expect(serverDisplayName({ name: '', serverURL: '' })).toBe('New Server')
  })
})

describe('browser sign-in', () => {
  test('authorize URL and callback checks', async () => {
    const { http, requests } = scriptedHttp([{ status: 200, body: { access_token: 'A', refresh_token: 'R', expires_at: 100 } }])
    const signIn = new NativeSignIn(endpoint, 51234, http, makePKCE('verifier-123'), 'state-abc')
    const url = new URL(signIn.authorizeURL)
    expect(url.pathname).toBe('/auth/native/authorize')
    expect(url.searchParams.get('redirect_uri')).toBe('http://127.0.0.1:51234/callback')
    expect(url.searchParams.get('state')).toBe('state-abc')
    expect(url.searchParams.get('code_challenge_method')).toBe('S256')
    expect(url.searchParams.get('code_challenge')).toBe(makePKCE('verifier-123').challenge)
    expect(isNativeCallback('/callback?code=c')).toBe(true)
    expect(isNativeCallback('/favicon.ico')).toBe(false)
    expect(() => signIn.code('/callback?code=c&state=other')).toThrow()
    expect(() => signIn.code('/callback?error=access_denied&state=state-abc')).toThrow(/access_denied/)
    const tokens = await signIn.tokens('/callback?code=c1&state=state-abc')
    expect(tokens.access_token).toBe('A')
    expect(path(requests[0]!)).toBe('POST /auth/native/token')
    expect(JSON.parse(requests[0]!.body!)).toEqual({ code: 'c1', code_verifier: 'verifier-123' })
  })

  test('the pair round-trips as a secret', () => {
    const tokens = { access_token: 'A', refresh_token: 'R', provider: 'nous' }
    expect(nativeTokensFromSecret(nativeTokensSecret(tokens))).toEqual(tokens)
    expect(nativeTokensFromSecret('password')).toBeUndefined()
  })

  test('native connect refreshes once after a 401 and saves the new pair', async () => {
    const { http, requests } = scriptedHttp([
      { status: 401, body: { reason: 'session_expired' } },
      { status: 200, body: { access_token: 'A2', refresh_token: 'R2' } },
      { status: 200, body: { ticket: 'T' } },
    ])
    const rotated: string[] = []
    const session = new NativeTokenSession({ access_token: 'A1', refresh_token: 'R1', provider: 'nous' },
      (fresh) => { rotated.push(fresh.access_token + '/' + fresh.provider) })
    const connector = new DashboardConnector(endpoint, { kind: 'native', session }, http, () => new FakeTransport())
    expect(await connector.webSocketURL()).toBe('wss://hermes.example.ts.net/api/ws?ticket=T')
    expect(requests.map(path)).toEqual(['POST /api/auth/ws-ticket', 'POST /auth/native/refresh', 'POST /api/auth/ws-ticket'])
    expect(requests[2]!.headers?.Authorization).toBe('Bearer A2')
    expect(rotated).toEqual(['A2/nous'])
  })

  test('an expired token refreshes before the mint; a rejected refresh is final', async () => {
    const { http, requests } = scriptedHttp([{ status: 401, body: {} }])
    const session = new NativeTokenSession({ access_token: 'A1', refresh_token: 'R1', expires_at: 10 }, () => {}, 60, () => 1000)
    const connector = new DashboardConnector(endpoint, { kind: 'native', session }, http, () => new FakeTransport())
    await expect(connector.webSocketURL()).rejects.toMatchObject({ kind: 'unauthenticated', reason: 'refresh_rejected' })
    expect(requests.map(path)).toEqual(['POST /auth/native/refresh'])
  })

  test('concurrent refreshes of the same token share one call', async () => {
    let calls = 0
    const http: HttpClient = {
      async send() {
        calls += 1
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 5))
        return { status: 200, body: JSON.stringify({ access_token: 'A2', refresh_token: 'R2' }) }
      },
    }
    const session = new NativeTokenSession({ access_token: 'A1', refresh_token: 'R1' })
    const dashboard = new DashboardConnector(endpoint, { kind: 'native', session }, http, () => new FakeTransport()).dashboard
    const tokens = await Promise.all([session.refresh('A1', dashboard), session.refresh('A1', dashboard)])
    expect(tokens).toEqual(['A2', 'A2'])
    expect(calls).toBe(1)
    expect(await session.refresh('A1', dashboard)).toBe('A2')
  })
})

describe('local backend', () => {
  test('launch: serve on a free loopback port, token and parent in the environment', () => {
    const launch = localBackendLaunch('mac', '/usr/local/bin/hermes', 'tok', 42,
      { PATH: '/usr/bin', HERMES_PARENT_NONCE: 'x' }, '/Users/me')
    expect(launch.arguments).toEqual(['serve', '--host', '127.0.0.1', '--port', '0', '--isolated'])
    expect(launch.environment.HERMES_DASHBOARD_SESSION_TOKEN).toBe('tok')
    expect(launch.environment.HERMES_PARENT_PID).toBe('42')
    expect('HERMES_PARENT_NONCE' in launch.environment).toBe(false)
    expect(launch.environment.PATH!.split(':')[0]).toBe('/Users/me/.local/bin')
  })

  test('Windows candidates: the installer\u2019s launcher first, then the venv, then PATH', () => {
    expect(hermesCandidates('windows', { home: 'C:\\Users\\me', localAppData: 'C:\\Users\\me\\AppData\\Local', path: 'C:\\Tools\;C:\\bin' })).toEqual([
      'C:\\Users\\me\\AppData\\Local\\hermes\\bin\\hermes.exe',
      'C:\\Users\\me\\AppData\\Local\\hermes\\hermes-agent\\venv\\Scripts\\hermes.exe',
      'C:\\Users\\me\\hermes-agent\\.venv\\Scripts\\hermes.exe',
      'C:\\Tools\\hermes.exe',
      'C:\\bin\\hermes.exe',
    ])
  })
})

describe('settings values', () => {
  test('notification switches', () => {
    const prefs = decodeAlertPreferences({ isEnabled: true, kinds: { turnDone: false, bogus: true } })
    expect(isAlertOn(prefs, 'turnDone')).toBe(false)
    expect(isAlertOn(prefs, 'approval')).toBe(true)
    expect(isAlertOn(prefs, 'otherReply')).toBe(false)
    expect(isAlertOn(setAlertOn(prefs, 'otherReply', true), 'otherReply')).toBe(true)
    expect(isAlertOn({ ...defaultAlertPreferences, isEnabled: false }, 'approval')).toBe(false)
  })

  test('hidden sources', () => {
    const settings = setSourceHidden({ hiddenSources: [] }, ' TUI ', true)
    expect(settings.hiddenSources).toEqual(['tui'])
    expect(showsSource(settings, 'tui')).toBe(false)
    expect(showsSource(settings, null)).toBe(true)
    expect(setSourceHidden(settings, 'tui', false).hiddenSources).toEqual([])
  })
})

describe('ServerRegistry', () => {
  function makeHost(change: Partial<ServerHost> = {}) {
    const saved: unknown[] = []
    const secrets = new Map<string, string>()
    let n = 0
    const host: ServerHost = {
      platform: 'mac',
      makeID: () => `s${++n}`,
      makeConnection: () => new GatewayConnection({ tryingNoticeDelayMs: 10_000 }),
      makeConnector: () => ({ makeTransport: async () => { throw new DashboardError('unauthenticated', 401) } }),
      http: scriptedHttp([]).http,
      saveServers: async (servers, local) => { saved.push({ servers, local }) },
      loadSecret: async (id) => ({ value: secrets.get(id) ?? null, available: true }),
      saveSecret: async (id, value) => { if (value === null) secrets.delete(id); else secrets.set(id, value) },
      ...change,
    }
    return { host, saved, secrets }
  }

  test('migrates the first version\u2019s server and its secret', async () => {
    const { host, saved, secrets } = makeHost()
    const registry = new ServerRegistry(host)
    await registry.load({ server: { serverURL: 'https://hermes.example.ts.net', authMode: 'password', provider: 'basic', username: 'me' } },
      async () => 'pw')
    const [entry] = registry.get().servers
    expect(entry?.name).toBe('hermes')
    expect(entry?.hasSecret).toBe(true)
    expect(secrets.get(entry!.id)).toBe('pw')
    expect(saved).toHaveLength(1)
  })

  test('add reuses a blank server; connect without a secret says so', async () => {
    const { host } = makeHost()
    const registry = new ServerRegistry(host)
    await registry.load({ servers: [] })
    const id = registry.add()
    expect(registry.add()).toBe(id)
    expect(registry.sidebarServers).toHaveLength(0)
    registry.update(id, { serverURL: 'https://hermes.example.ts.net' })
    expect(await registry.connect(id)).toBe(false)
    expect(registry.server(id)?.lastError).toBe('No password for hermes. Enter it in Settings.')
  })

  test('connect saves first; a failure is the server\u2019s error; remove forgets the secret', async () => {
    const { host, saved, secrets } = makeHost()
    const registry = new ServerRegistry(host)
    await registry.load({ servers: [] })
    const id = registry.add({ serverURL: 'https://hermes.example.ts.net' })
    registry.setSecret(id, 'pw')
    expect(await registry.connect(id)).toBe(false)
    expect(secrets.get(id)).toBe('pw')
    expect(saved.at(-1)).toMatchObject({ servers: [{ id, serverURL: 'https://hermes.example.ts.net' }] })
    expect(registry.server(id)?.lastError).toBe('Not signed in, or the session expired.')
    await registry.remove(id)
    expect(registry.get().servers).toHaveLength(0)
    expect(secrets.has(id)).toBe(false)
  })

  test('Check Server', async () => {
    const { host } = makeHost({ http: scriptedHttp([{ status: 200, body: { version: '0.23.1', auth_required: true, auth_flows: ['cookie', 'native_pkce'] } }]).http })
    const registry = new ServerRegistry(host)
    await registry.load({ servers: [{ id: 'a', serverURL: 'https://hermes.example.ts.net' }] })
    await registry.probe('a')
    expect(registry.server('a')?.probeResult).toBe('Hermes 0.23.1 \u00b7 sign-in required (cookie, native_pkce)')
  })

  test('browser sign-in keeps the pair and connects', async () => {
    const opened: string[] = []
    let stopped = false
    const { http } = scriptedHttp([{ status: 200, body: { access_token: 'A', refresh_token: 'R' } }])
    const { host, secrets } = makeHost({
      http,
      signIn: {
        listen: async () => {
          let resolve!: (target: string) => void
          const callback = new Promise<string>((done) => { resolve = done })
          setTimeout(() => {
            const state = new URL(opened[0]!).searchParams.get('state')
            resolve(`/callback?code=c&state=${state}`)
          }, 5)
          return { port: 50000, callback, stop: () => { stopped = true } }
        },
        openExternal: async (url) => { opened.push(url) },
      },
    })
    const registry = new ServerRegistry(host)
    await registry.load({ servers: [{ id: 'a', serverURL: 'https://hermes.example.ts.net' }] })
    await registry.signInWithBrowser('a')
    expect(stopped).toBe(true)
    const entry = registry.server('a')!
    expect(entry.config.authMode).toBe('browser')
    expect(entry.isSignedInWithBrowser).toBe(true)
    expect(nativeTokensFromSecret(secrets.get('a')!)?.access_token).toBe('A')
  })

  test('the local backend: started, named for the platform, never saved as a server', async () => {
    let started = 0
    const { host, saved } = makeHost({
      platform: 'windows',
      localBackend: {
        available: async () => true,
        start: async () => { started += 1; return { port: 61000, token: 'tok' } },
        stop: async () => {},
        isRunning: async () => true,
      },
    })
    const registry = new ServerRegistry(host)
    await registry.load({ servers: [] })
    await registry.setRunsLocalBackend(true)
    const [local] = registry.get().servers
    expect(local?.name).toBe('This PC')
    expect(local?.isLocal).toBe(true)
    expect(local?.config.serverURL).toBe('http://127.0.0.1:61000')
    expect(started).toBe(1)
    expect(saved.at(-1)).toEqual({ servers: [], local: true })
    await registry.setRunsLocalBackend(false)
    expect(registry.get().servers).toHaveLength(0)
  })
})
