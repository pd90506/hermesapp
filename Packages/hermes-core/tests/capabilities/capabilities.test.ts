import { describe, expect, test } from 'vitest'
import {
  CapabilitiesBoard, DashboardRequestError, capabilityNote, filterCapabilities, mcpCapability, pluginCapability,
  skillCapability, toolsetCapability, type JSONValue,
} from '../../src/index.ts'
import { FakeDashboardAPI, access } from '../support/fake-dashboard-api.ts'

// The cases of HermesKit's ProfileSettingsTests (CapabilityRowTests, CapabilitiesBoardTests).
describe('capability rows', () => {
  test('skills, toolsets and MCP servers', () => {
    const skill = skillCapability({ name: 'arxiv', description: 'Papers', category: 'research', enabled: false, usage: 3, provenance: 'bundled' })!
    expect(skill.tags).toEqual(['research', 'bundled'])
    expect(skill.isEnabled).toBe(false)

    const toolset = toolsetCapability({
      name: 'web', label: 'Web Search', description: 'Search', platform: 'cli',
      enabled: true, available: true, configured: false, tools: ['web_search', 'web_extract'],
    })!
    expect(toolset.title).toBe('Web Search')
    expect(toolset.tags).toEqual(['2 tools'])
    expect(toolset.needsSetup).toBe(true)
    expect(capabilityNote(toolset)).toBe('Needs keys or setup in Hermes · 2 tools')

    const stdio = mcpCapability({ name: 'files', transport: 'stdio', url: null, command: 'npx', args: ['-y', 'server-files'], enabled: true, source: 'config', plugin: null })!
    expect(stdio.detail).toBe('npx -y server-files')
    expect(stdio.lockedReason).toBeUndefined()
    const fromPlugin = mcpCapability({ name: 'meshy', url: 'http://127.0.0.1:9', transport: 'http', enabled: true, source: 'plugin', plugin: 'meshy' })!
    expect(fromPlugin.lockedReason).toBe('Provided by the meshy plugin')
  })

  // `isDesktopRelevantPlugin` (`apps/desktop/src/store/agent-plugins.ts:111-132`).
  test('plugins the user manages', () => {
    const row = (name: string, key: string | null, source: string, status = 'enabled'): JSONValue =>
      ({ name, key, version: '1.2', description: '', source, status })
    expect(pluginCapability(row('kanban', 'kanban', 'user'))?.name).toBe('kanban')
    expect(pluginCapability(row('kanban', 'kanban', 'user'))?.tags).toEqual(['user', 'v1.2'])
    expect(pluginCapability(row('disk-cleanup', 'disk-cleanup', 'bundled', 'not enabled'))?.isEnabled).toBe(false)
    expect(pluginCapability(row('fal', 'image_gen/fal', 'bundled'))).toBeUndefined()
    expect(pluginCapability(row('telegram', 'platforms/telegram', 'git'))).toBeUndefined()
    // A row without a key can't be addressed safely.
    expect(pluginCapability(row('old', null, 'user'))?.lockedReason).toBeDefined()
  })

  test('search matches title, name, detail and tags, ignoring case and accents', () => {
    const rows = [skillCapability({ name: 'arxiv', description: 'Papers', category: 'Recherche' })!,
      skillCapability({ name: 'café-notes', description: 'Notes' })!]
    expect(filterCapabilities(rows, 'PAPER').map((r) => r.name)).toEqual(['arxiv'])
    expect(filterCapabilities(rows, 'cafe').map((r) => r.name)).toEqual(['café-notes'])
    expect(filterCapabilities(rows, 'recherche').map((r) => r.name)).toEqual(['arxiv'])
    expect(filterCapabilities(rows, '  ')).toHaveLength(2)
  })
})

describe('CapabilitiesBoard', () => {
  test('reads and switches over REST and the gateway', async () => {
    const api = new FakeDashboardAPI({
      'GET /api/skills': [{ name: 'b-skill', enabled: true }, { name: 'a-skill', enabled: false }],
      'PUT /api/skills/toggle': { ok: true, name: 'a-skill', enabled: true },
      'GET /api/mcp/servers': { servers: [{ name: 'my files', command: 'npx', enabled: true }] },
      'PUT /api/mcp/servers/my%20files/enabled': { ok: true },
    })
    const gateway = access(api, (_method, params) => params.action === 'toggle'
      ? { ok: true, name: 'kanban' }
      : { plugins: [{ name: 'kanban', key: 'kanban', source: 'user', status: 'disabled' }] })
    const board = new CapabilitiesBoard(gateway)

    await board.refresh('skills', 'coder')
    expect(board.get().lists.skills?.map((r) => r.name)).toEqual(['a-skill', 'b-skill'])
    await board.setEnabled(board.get().lists.skills![0]!, true)
    expect(board.get().lists.skills?.[0]?.isEnabled).toBe(true)
    expect(api.callsOf('PUT').at(-1)).toEqual({ method: 'PUT', path: '/api/skills/toggle', query: { profile: 'coder' }, body: { name: 'a-skill', enabled: true } })

    await board.refresh('mcp', 'coder')
    await board.setEnabled(board.get().lists.mcp![0]!, false)
    expect(api.callsOf('PUT').at(-1)?.path).toBe('/api/mcp/servers/my%20files/enabled')
    expect(board.get().lists.mcp?.[0]?.isEnabled).toBe(false)

    await board.refresh('plugins', 'coder')
    await board.setEnabled(board.get().lists.plugins![0]!, true)
    expect(gateway.gatewayCalls.at(-1)).toEqual({ method: 'plugins.manage', params: { action: 'toggle', key: 'kanban', enable: true, profile: 'coder' } })
    expect(board.get().lists.plugins?.[0]?.isEnabled).toBe(true)
    expect(board.get().loading.size).toBe(0)
  })

  test('a refusal flips the switch back', async () => {
    const api = new FakeDashboardAPI({ 'GET /api/tools/toolsets': [{ name: 'web', enabled: true, tools: [] }] })
    api.on('PUT /api/tools/toolsets/web', new DashboardRequestError(400, 'Unknown toolset'))
    const board = new CapabilitiesBoard(access(api))
    await board.refresh('toolsets', 'default')
    const row = board.get().lists.toolsets![0]!
    await expect(board.setEnabled(row, false)).rejects.toThrow('Unknown toolset')
    expect(board.get().lists.toolsets?.[0]?.isEnabled).toBe(true)
    expect(board.get().saving.size).toBe(0)
  })

  test('a locked row does not switch', async () => {
    const api = new FakeDashboardAPI({ 'GET /api/mcp/servers': { servers: [{ name: 'meshy', plugin: 'meshy', enabled: true }] } })
    const board = new CapabilitiesBoard(access(api))
    await board.refresh('mcp', 'default')
    await board.setEnabled(board.get().lists.mcp![0]!, false)
    expect(api.callsOf('PUT')).toEqual([])
  })

  test('another profile starts empty', async () => {
    const api = new FakeDashboardAPI({ 'GET /api/skills': [{ name: 'x' }] })
    const board = new CapabilitiesBoard(access(api))
    await board.refresh('skills', 'coder')
    expect(board.get().lists.skills).toHaveLength(1)
    api.on('GET /api/skills', new DashboardRequestError(500, 'boom'))
    await board.refresh('skills', 'default')
    expect(board.get().lists.skills).toBeUndefined()
    expect(board.get().errors.skills).toBe('boom')
  })

  test('without REST access the page is not available, plugins still read', async () => {
    const board = new CapabilitiesBoard(access(undefined, () => ({ plugins: [] })))
    await board.refresh('skills', 'default')
    expect(board.get().isAvailable).toBe(false)
    await board.refresh('plugins', 'default')
    expect(board.get().lists.plugins).toEqual([])
  })
})
