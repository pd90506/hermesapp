import { describe, expect, test } from 'vitest'
import {
  ProvidersBoard, accountIsConnected, accountSignsInHere, accountStatus, endpointDraftBody, endpointDraftCanSave,
  filterKeyGroups, providerAccount, providerKeyGroups, type JSONValue,
} from '../../src/index.ts'
import { FakeDashboardAPI, access, eventually } from '../support/fake-dashboard-api.ts'

// The cases of HermesKit's ProfileSettingsTests (ProviderRowTests, ProvidersBoardTests).
/** `GET /api/env` rows (`hermes_cli/web_routers/config_env.py:266-325`). */
const envRows: JSONValue = {
  ANTHROPIC_API_KEY: { is_set: true, redacted_value: 'sk-…abcd', description: 'Anthropic API key',
    url: 'https://console.anthropic.com', category: 'provider', is_password: true, advanced: false,
    provider: 'anthropic', provider_label: 'Anthropic', provider_profiles: [], provider_primary: true },
  ANTHROPIC_TOKEN: { is_set: false, category: 'provider', is_password: true, provider: 'anthropic', provider_label: 'Anthropic' },
  ANTHROPIC_BASE_URL: { is_set: false, category: 'provider', is_password: false, advanced: true, provider: 'anthropic', provider_label: 'Anthropic' },
  DASHSCOPE_API_KEY: { is_set: false, category: 'provider', is_password: true, provider: 'alibaba', provider_label: 'Alibaba',
    provider_profiles: [
      { provider: 'alibaba', provider_label: 'Alibaba', description: 'Qwen', primary: true },
      { provider: 'alibaba-coding', provider_label: 'Alibaba Coding Plan', description: 'Coding', primary: false },
    ] },
  MYSTERY_KEY: { is_set: false, category: 'provider', is_password: true },
  GITHUB_TOKEN: { is_set: true, category: 'tool', is_password: true },
}

describe('provider rows', () => {
  // `buildProviderKeyGroups` (`apps/desktop/src/app/settings/providers-settings.tsx:74-144`).
  test('key groups', () => {
    const groups = providerKeyGroups(envRows)
    expect(groups.map((g) => g.name)).toEqual(['Anthropic', 'Alibaba', 'Alibaba Coding Plan'])
    const anthropic = groups[0]!
    expect(anthropic.primary.key).toBe('ANTHROPIC_API_KEY')
    // An unset alias key gets no second field.
    expect(anthropic.others.map((v) => v.key)).toEqual(['ANTHROPIC_BASE_URL'])
    expect(anthropic.hasAnySet).toBe(true)
    expect(anthropic.docsURL).toBe('https://console.anthropic.com')
    expect(groups[2]!.primary.key).toBe('DASHSCOPE_API_KEY')
    expect(groups[2]!.description).toBe('Coding')
  })

  test('key search', () => {
    const groups = providerKeyGroups(envRows)
    expect(filterKeyGroups(groups, 'base_url').map((g) => g.name)).toEqual(['Anthropic'])
    expect(filterKeyGroups(groups, 'coding').map((g) => g.name)).toEqual(['Alibaba Coding Plan'])
    expect(filterKeyGroups(groups, '')).toHaveLength(3)
  })

  test('accounts', () => {
    const account = providerAccount({
      id: 'nous', name: 'Nous Portal', flow: 'device_code', cli_command: 'hermes auth add nous',
      docs_url: '', disconnect_hint: null, disconnect_command: null, disconnectable: true,
      status: { logged_in: true, source: 'nous_portal', source_label: 'Nous Portal', token_preview: '…9f2a',
        expires_at: null, has_refresh_token: true, free_tier: true },
    })!
    expect(accountSignsInHere(account)).toBe(true)
    // The free tier isn't a connected account.
    expect(account.isSignedIn && !accountIsConnected(account)).toBe(true)
    expect(account.docsURL).toBeUndefined()
    expect(accountStatus(account)).toBe('Free tier · sign in for your account')
    expect(accountStatus({ ...account, isFreeTier: false })).toBe('Connected · Nous Portal · …9f2a')
    expect(accountStatus({ ...account, isSignedIn: false, isFreeTier: false, flow: 'external' })).toBe('Sign in on the server: hermes auth add nous')
  })

  test('endpoint draft', () => {
    const draft = { name: ' Lab ', baseURL: 'http://lab:8000/v1', model: 'qwen', apiKey: '  ', makeDefault: true }
    expect(endpointDraftCanSave(draft)).toBe(true)
    expect(endpointDraftCanSave({ ...draft, model: ' ' })).toBe(false)
    expect(endpointDraftBody(draft)).toEqual({ name: 'Lab', base_url: 'http://lab:8000/v1', model: 'qwen', make_default: true })
    expect(endpointDraftBody({ ...draft, apiKey: 'sk-1' })).toMatchObject({ api_key: 'sk-1' })
  })
})

function api(): FakeDashboardAPI {
  return new FakeDashboardAPI({
    'GET /api/env': envRows,
    'GET /api/providers/oauth': { providers: [
      { id: 'openai-codex', name: 'ChatGPT', flow: 'device_code', disconnectable: true, status: { logged_in: false } },
    ] },
    'GET /api/providers/custom-endpoints': {
      endpoints: [{ id: 'lab', name: 'Lab', base_url: 'http://lab.example:8000/v1', model: 'qwen', models: ['qwen'], has_api_key: false, is_current: true }],
      current: { provider: 'lab', model: 'qwen', base_url: 'http://lab.example:8000/v1' },
    },
    'PUT /api/env': { ok: true },
    'DELETE /api/env': { ok: true, found: true },
    'POST /api/providers/custom-endpoints/lab/activate': { ok: true },
  })
}

describe('ProvidersBoard', () => {
  test('reads the page', async () => {
    const fake = api()
    const board = new ProvidersBoard(access(fake))
    await board.refresh('coder')
    const page = board.get()
    expect(page.keyGroups).toHaveLength(3)
    expect(page.accounts.map((a) => a.id)).toEqual(['openai-codex'])
    expect(page.endpoints[0]?.isCurrent).toBe(true)
    expect(page.currentModel).toBe('qwen')
    expect(page.currentProvider).toBe('lab')
    expect(page.hasLoaded && !page.isLoading).toBe(true)
    expect(new Set(fake.calls.map((c) => c.query.profile))).toEqual(new Set(['coder']))
  })

  test('accounts and endpoints are best effort', async () => {
    const fake = api()
    fake.on('GET /api/providers/oauth', new Error('down'))
    const board = new ProvidersBoard(access(fake))
    await board.refresh('coder')
    expect(board.get().error).toBeUndefined()
    expect(board.get().keyGroups).toHaveLength(3)
    expect(board.get().accounts).toEqual([])
  })

  test('keys are saved and removed', async () => {
    const fake = api()
    const board = new ProvidersBoard(access(fake))
    await board.refresh('coder')
    await board.setKey('ANTHROPIC_API_KEY', ' sk-new \n')
    expect(fake.callsOf('PUT').at(-1)?.body).toEqual({ key: 'ANTHROPIC_API_KEY', value: 'sk-new', provider_setup: true })
    await board.removeKey('ANTHROPIC_API_KEY')
    expect(fake.callsOf('DELETE').at(-1)?.body).toEqual({ key: 'ANTHROPIC_API_KEY' })
    await board.activateEndpoint(board.get().endpoints[0]!)
    // Each write re-reads the page.
    expect(fake.calls.filter((c) => c.path === '/api/env' && c.method === 'GET')).toHaveLength(4)
    expect(board.get().saving.size).toBe(0)
  })

  test('no REST access', async () => {
    const board = new ProvidersBoard(access(undefined))
    await board.refresh('coder')
    expect(board.get().isAvailable).toBe(false)
  })

  // `start` gives the code; `poll?wait=` long-polls until the session leaves `pending`
  // (`hermes_cli/web_routers/oauth.py:794-905`).
  test('device-code sign-in', async () => {
    const fake = api()
    fake.on('POST /api/providers/oauth/openai-codex/start', { session_id: 's1', flow: 'device_code', user_code: 'ABCD-1234',
      verification_url: 'https://auth.example.com/device', expires_in: 900, poll_interval: 5 })
    fake.on('GET /api/providers/oauth/openai-codex/poll/s1', { session_id: 's1', status: 'pending' }, { session_id: 's1', status: 'approved' })
    const board = new ProvidersBoard(access(fake))
    await board.refresh('coder')
    await board.startSignIn(board.get().accounts[0]!)
    expect(board.get().signIn?.userCode).toBe('ABCD-1234')
    expect(board.get().signIn?.verificationURL).toBe('https://auth.example.com/device')
    await eventually(() => board.get().signIn?.status.phase === 'approved')
    const polls = fake.calls.filter((c) => c.path.endsWith('/poll/s1'))
    expect(polls).toHaveLength(2)
    expect(polls[0]?.query).toEqual({ profile: 'coder', wait: '25' })
    board.cancelSignIn()
    expect(board.get().signIn).toBeUndefined()
    // An approved session isn't deleted on the server.
    expect(fake.callsOf('DELETE')).toEqual([])
  })

  test('cancelling a waiting sign-in drops the server session', async () => {
    const fake = api()
    fake.on('POST /api/providers/oauth/openai-codex/start', { session_id: 's 2', user_code: 'X' })
    let release!: () => void
    fake.on('GET /api/providers/oauth/openai-codex/poll/s%202', { status: 'pending' })
    const send = fake.send.bind(fake)
    fake.send = async (method, path, options) => {
      if (path.includes('/poll/')) await new Promise<void>((resolve) => { release = resolve })
      return send(method, path, options)
    }
    const board = new ProvidersBoard(access(fake))
    await board.refresh('coder')
    await board.startSignIn(board.get().accounts[0]!)
    board.cancelSignIn()
    expect(fake.callsOf('DELETE').at(-1)?.path).toBe('/api/providers/oauth/sessions/s%202')
    release()
  })

  test('a failed sign-in shows why', async () => {
    const fake = api()
    fake.on('POST /api/providers/oauth/openai-codex/start', { session_id: 's1', user_code: 'X' })
    fake.on('GET /api/providers/oauth/openai-codex/poll/s1', { status: 'denied', error_message: 'Access denied' })
    const board = new ProvidersBoard(access(fake))
    await board.refresh('coder')
    await board.startSignIn(board.get().accounts[0]!)
    await eventually(() => board.get().signIn?.status.phase === 'failed')
    expect(board.get().signIn?.status).toEqual({ phase: 'failed', reason: 'Access denied' })
  })
})
