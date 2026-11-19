import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import {
  Bot, CapabilitiesBoard, DashboardRequestError, Observable, ProvidersBoard,
  type ConnectionSnapshot, type DashboardAPI, type DashboardCallOptions, type JSONValue,
} from '@talaria/hermes-core'
import { CapabilitiesPane } from '../../src/renderer/features/settings/capabilities/CapabilitiesPane.tsx'
import { ProvidersPane, type SettingsConnection } from '../../src/renderer/features/settings/providers/ProvidersPane.tsx'

class FakeConnection extends Observable<ConnectionSnapshot> implements SettingsConnection {
  readonly calls: Array<{ method: string; path: string; query: Record<string, string>; body?: JSONValue }> = []
  gateway: (method: string, params: any) => JSONValue = () => ({ plugins: [] })
  readonly dashboardAPI: DashboardAPI

  constructor(private readonly answers: Record<string, JSONValue | Error>, snapshot: Partial<ConnectionSnapshot> = {}) {
    super({
      link: { phase: 'connected' }, isTryingNoticeably: false, sessions: {}, sessionListLoading: false,
      bots: [new Bot({ name: 'default', display_name: 'Hermes' }), new Bot({ name: 'coder', display_name: 'Coder' })],
      selectedProfile: 'coder',
      ...snapshot,
    })
    this.dashboardAPI = {
      send: async (method: string, path: string, options: DashboardCallOptions = {}) => {
        this.calls.push({ method, path, query: Object.fromEntries(options.query ?? []), ...(options.body !== undefined ? { body: options.body } : {}) })
        const answer = this.answers[`${method} ${path}`]
        if (answer === undefined) throw new DashboardRequestError(404, `unscripted ${method} ${path}`)
        if (answer instanceof Error) throw answer
        return answer
      },
    }
  }

  async call(method: string, params?: JSONValue): Promise<JSONValue> {
    return this.gateway(method, params)
  }

  put(change: Partial<ConnectionSnapshot>): void { this.set({ ...this.get(), ...change }) }
}

afterEach(cleanup)

const env: JSONValue = {
  ANTHROPIC_API_KEY: { is_set: true, redacted_value: 'sk-…abcd', description: 'Anthropic API key', url: 'https://console.anthropic.com',
    category: 'provider', is_password: true, provider: 'anthropic', provider_label: 'Anthropic', provider_primary: true },
  OPENAI_API_KEY: { is_set: false, description: 'OpenAI key', category: 'provider', is_password: true, provider: 'openai', provider_label: 'OpenAI' },
}

function providers(extra: Record<string, JSONValue | Error> = {}) {
  return new FakeConnection({
    'GET /api/env': env,
    'GET /api/providers/oauth': { providers: [
      { id: 'openai-codex', name: 'ChatGPT', flow: 'device_code', disconnectable: true, status: { logged_in: false } },
      { id: 'nous', name: 'Nous Portal', flow: 'device_code', disconnectable: true, status: { logged_in: true, source_label: 'Nous Portal', token_preview: '…9f2a' } },
    ] },
    'GET /api/providers/custom-endpoints': {
      endpoints: [{ id: 'lab', name: 'Lab', base_url: 'http://lab.example:8000/v1', model: 'qwen', is_current: true }],
      current: { provider: 'lab', model: 'qwen' },
    },
    'PUT /api/env': { ok: true },
    ...extra,
  })
}

describe('ProvidersPane', () => {
  it('reads the session list\'s profile and shows its accounts', async () => {
    const connection = providers()
    render(<ProvidersPane connection={connection} />)
    expect(await screen.findByText('ChatGPT')).toBeTruthy()
    expect(screen.getByText('Not connected')).toBeTruthy()
    expect(screen.getByText('Connected · Nous Portal · …9f2a')).toBeTruthy()
    expect(screen.getByText('qwen · lab')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Disconnect' })).toBeTruthy()
    expect(new Set(connection.calls.map((c) => c.query.profile))).toEqual(new Set(['coder']))
  })

  it('sets a key from the API Keys page', async () => {
    const connection = providers()
    render(<ProvidersPane connection={connection} />)
    await screen.findByText('ChatGPT')
    fireEvent.click(screen.getByRole('tab', { name: 'API Keys' }))
    expect(screen.getByText('Anthropic')).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Search providers'), { target: { value: 'openai' } })
    expect(screen.queryByText('Anthropic')).toBeNull()
    fireEvent.click(screen.getByTestId('providerKey.set.OPENAI_API_KEY'))
    const dialog = screen.getByRole('dialog', { name: 'Set OPENAI_API_KEY' })
    const input = within(dialog).getByLabelText('Value') as HTMLInputElement
    expect(input.type).toBe('password')
    fireEvent.change(input, { target: { value: ' sk-new ' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(connection.calls.some((c) => c.method === 'PUT')).toBe(true))
    expect(connection.calls.find((c) => c.method === 'PUT')).toEqual({
      method: 'PUT', path: '/api/env', query: { profile: 'coder' }, body: { key: 'OPENAI_API_KEY', value: 'sk-new', provider_setup: true },
    })
  })

  it('shows a refused change', async () => {
    const connection = providers({ 'POST /api/providers/oauth/openai-codex/start': new DashboardRequestError(400, 'Sign-in is off') })
    render(<ProvidersPane connection={connection} />)
    fireEvent.click(await screen.findByTestId('providerSignIn.openai-codex'))
    expect((await screen.findByRole('alert')).textContent).toBe('Sign-in is off')
  })

  it('shows the device code while Hermes waits', async () => {
    const connection = providers({
      'POST /api/providers/oauth/openai-codex/start': { session_id: 's1', user_code: 'ABCD-1234', verification_url: 'https://auth.example.com/device' },
    })
    const board = new ProvidersBoard(connection)
    // The poll never answers in this test: it stays waiting.
    const send = connection.dashboardAPI.send
    ;(connection.dashboardAPI as { send: DashboardAPI['send'] }).send = (method, path, options) =>
      path.includes('/poll/') ? new Promise(() => {}) : send(method, path, options)
    render(<ProvidersPane connection={connection} board={board} />)
    fireEvent.click(await screen.findByTestId('providerSignIn.openai-codex'))
    expect((await screen.findByTestId('providerSignIn.code')).textContent).toBe('ABCD-1234')
    expect(screen.getByRole('link', { name: 'Open Sign-In Page' }).getAttribute('href')).toBe('https://auth.example.com/device')
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(board.get().signIn).toBeUndefined()
  })

  it('says when it is not connected', () => {
    const connection = providers()
    connection.put({ link: { phase: 'disconnected' } })
    render(<ProvidersPane connection={connection} />)
    expect(screen.getByText('Connect to the server to set up its providers.')).toBeTruthy()
  })
})

describe('CapabilitiesPane', () => {
  function capabilities() {
    const connection = new FakeConnection({
      'GET /api/skills': [{ name: 'arxiv', description: 'Papers', category: 'research', enabled: false }, { name: 'web', enabled: true }],
      'PUT /api/skills/toggle': { ok: true },
      'GET /api/tools/toolsets': [{ name: 'browser', label: 'Browser', enabled: true, configured: false, tools: ['a', 'b'] }],
      'GET /api/mcp/servers': new DashboardRequestError(500, 'boom'),
    })
    return connection
  }

  it('lists skills and switches one', async () => {
    const connection = capabilities()
    render(<CapabilitiesPane connection={connection} />)
    const toggle = await screen.findByRole('switch', { name: 'arxiv' }) as HTMLInputElement
    expect(toggle.checked).toBe(false)
    expect(screen.getByText('research')).toBeTruthy()
    fireEvent.click(toggle)
    expect(toggle.checked).toBe(true)
    await waitFor(() => expect(connection.calls.at(-1)?.body).toEqual({ name: 'arxiv', enabled: true }))
  })

  it('searches, switches kind, and shows a failed list', async () => {
    const connection = capabilities()
    render(<CapabilitiesPane connection={connection} />)
    await screen.findByRole('switch', { name: 'arxiv' })
    fireEvent.change(screen.getByLabelText('Search'), { target: { value: 'pap' } })
    expect(screen.queryByRole('switch', { name: 'web' })).toBeNull()
    fireEvent.change(screen.getByLabelText('Search'), { target: { value: 'zzz' } })
    expect(screen.getByText('No Results for “zzz”')).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Search'), { target: { value: '' } })
    fireEvent.click(screen.getByRole('tab', { name: 'Toolsets' }))
    expect(await screen.findByText('Needs keys or setup in Hermes · 2 tools')).toBeTruthy()
    fireEvent.click(screen.getByRole('tab', { name: 'MCP Servers' }))
    expect(await screen.findByText('Couldn\'t Load MCP Servers')).toBeTruthy()
    expect(screen.getByText('boom')).toBeTruthy()
  })

  it('reads another profile when one is picked', async () => {
    const connection = capabilities()
    const board = new CapabilitiesBoard(connection)
    render(<CapabilitiesPane connection={connection} board={board} />)
    await screen.findByRole('switch', { name: 'arxiv' })
    await act(async () => { fireEvent.change(screen.getByLabelText('Profile'), { target: { value: 'default' } }) })
    await waitFor(() => expect(board.get().profile).toBe('default'))
    expect(connection.calls.at(-1)?.query).toEqual({ profile: 'default' })
  })
})
