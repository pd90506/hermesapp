import { GatewayClientError } from '../client.ts'
import { pathSegment, profileGet, profilePut, type GatewayAccess } from '../dashboard-api.ts'
import { describeError } from '../describe.ts'
import { arrayOf, boolOf, field, standardCompare, standardContains, stringOf, textOf } from '../json-read.ts'
import { Observable } from '../observable.ts'
import { RPCError, type JSONValue } from '../protocol/jsonrpc.ts'

/**
 * A profile's installed capabilities, each with its on/off switch: Desktop's Capabilities
 * page without its catalogs (`apps/desktop/src/app/capabilities/`; HermesKit's
 * `Capabilities`). Skills, toolsets and MCP servers are read and switched over REST, as
 * Desktop does; plugins over the gateway's `plugins.manage` (`apps/desktop/src/store/agent-plugins.ts`).
 */
export type CapabilityKind = 'skills' | 'toolsets' | 'mcp' | 'plugins'

export const capabilityKinds: readonly CapabilityKind[] = ['skills', 'toolsets', 'mcp', 'plugins']

export const capabilityTitles: Readonly<Record<CapabilityKind, string>> = {
  skills: 'Skills',
  toolsets: 'Toolsets',
  mcp: 'MCP Servers',
  plugins: 'Plugins',
}

/** One row of a capability list. */
export interface Capability {
  kind: CapabilityKind
  /** What the switch is addressed by: the skill, toolset or server name, the plugin's key. */
  name: string
  title: string
  detail: string
  /** Where it comes from or what it holds (`bundled`, `hub`, `stdio`, `12 tools`, a version). */
  tags: string[]
  isEnabled: boolean
  /** Undefined when the switch can flip; otherwise why not. */
  lockedReason?: string
  /** A toolset whose keys aren't set yet: on, it still can't run (`_toolset_has_keys`). */
  needsSetup: boolean
}

export function capabilityID(row: Pick<Capability, 'kind' | 'name'>): string {
  return `${row.kind}:${row.name}`
}

/** The small line under a row: setup needed, its tags, why it's locked (`CapabilityRow.note`). */
export function capabilityNote(row: Capability): string | undefined {
  const parts = [...(row.needsSetup ? ['Needs keys or setup in Hermes'] : []), ...row.tags,
    ...(row.lockedReason ? [row.lockedReason] : [])]
  return parts.length > 0 ? parts.join(' · ') : undefined
}

function make(kind: CapabilityKind, name: string, rest: Partial<Capability> & { isEnabled: boolean }): Capability {
  return { kind, name, title: name, detail: '', tags: [], needsSetup: false, ...rest }
}

function strings(values: Array<string | undefined>): string[] {
  return values.filter((s): s is string => s !== undefined && s !== '')
}

/** A `GET /api/skills` row (`hermes_cli/web_routers/skills.py:343-376`). */
export function skillCapability(json: JSONValue): Capability | undefined {
  const name = textOf(field(json, 'name'))
  if (!name) return undefined
  return make('skills', name, {
    detail: stringOf(field(json, 'description')) ?? '',
    tags: strings([stringOf(field(json, 'category')), stringOf(field(json, 'provenance'))]),
    isEnabled: boolOf(field(json, 'enabled')) ?? true,
  })
}

/** A `GET /api/tools/toolsets` row (`hermes_cli/web_routers/tools.py:223-270`). */
export function toolsetCapability(json: JSONValue): Capability | undefined {
  const name = textOf(field(json, 'name'))
  if (!name) return undefined
  const tools = arrayOf(field(json, 'tools'))?.length ?? 0
  return make('toolsets', name, {
    title: stringOf(field(json, 'label')) ?? name,
    detail: stringOf(field(json, 'description')) ?? '',
    tags: tools > 0 ? [tools === 1 ? '1 tool' : `${tools} tools`] : [],
    isEnabled: boolOf(field(json, 'enabled')) ?? false,
    needsSetup: boolOf(field(json, 'configured')) === false,
  })
}

/**
 * A `GET /api/mcp/servers` row (`hermes_cli/web_server_mcp.py::_mcp_server_summary`). A
 * plugin's server is switched with its plugin: the route refuses it (409, `mcp.py:372-395`).
 */
export function mcpCapability(json: JSONValue): Capability | undefined {
  const name = textOf(field(json, 'name'))
  if (!name) return undefined
  const args = (arrayOf(field(json, 'args')) ?? []).flatMap((a) => (typeof a === 'string' ? [a] : []))
  const command = stringOf(field(json, 'command'))
  const target = stringOf(field(json, 'url')) ?? [...(command !== undefined ? [command] : []), ...args].join(' ')
  const plugin = stringOf(field(json, 'plugin'))
  const transport = stringOf(field(json, 'transport'))
  const row = make('mcp', name, {
    detail: target,
    tags: transport !== undefined && transport !== 'unknown' ? [transport] : [],
    isEnabled: boolOf(field(json, 'enabled')) ?? true,
  })
  if (plugin !== undefined) row.lockedReason = `Provided by the ${plugin} plugin`
  return row
}

/**
 * A `plugins.manage` `list` row (`tui_gateway/methods_tools.py:1662-1700`), when the
 * Plugins page lists it: plugins the user installed, plus the bundled ones that switch
 * like them (`isDesktopRelevantPlugin`, `apps/desktop/src/store/agent-plugins.ts:111-132`).
 */
export function pluginCapability(json: JSONValue): Capability | undefined {
  const name = textOf(field(json, 'name'))
  if (!name) return undefined
  const key = textOf(field(json, 'key'))
  const source = stringOf(field(json, 'source')) ?? ''
  if (source === 'bundled') {
    if (!['disk-cleanup', 'security-guidance'].includes(key ?? name)) return undefined
  } else if (key && ['dashboard_auth/', 'model-providers/', 'platforms/'].some((prefix) => key.startsWith(prefix))) {
    return undefined
  }
  const version = textOf(field(json, 'version'))
  const row = make('plugins', key ?? name, {
    title: name,
    detail: stringOf(field(json, 'description')) ?? '',
    tags: strings([source, version !== undefined ? `v${version}` : undefined]),
    isEnabled: stringOf(field(json, 'status')) === 'enabled',
  })
  if (key === undefined) row.lockedReason = 'Update Hermes to switch this plugin from here'
  return row
}

/** The rows whose title, name, detail or tags hold `query` (the page's search field). */
export function filterCapabilities(rows: readonly Capability[], query: string): readonly Capability[] {
  const words = query.trim()
  if (words === '') return rows
  return rows.filter((row) => [row.title, row.name, row.detail, ...row.tags].some((text) => standardContains(text, words)))
}

/** What the Capabilities page shows for one profile (HermesKit's `CapabilitiesBoard`). */
export interface CapabilitiesSnapshot {
  /** The profile the lists are of: undefined until one is read. */
  profile?: string
  /** Each list once read; a kind not read yet is missing. */
  lists: Readonly<Partial<Record<CapabilityKind, readonly Capability[]>>>
  errors: Readonly<Partial<Record<CapabilityKind, string>>>
  loading: ReadonlySet<CapabilityKind>
  /** Rows whose switch is being saved, by `capabilityID`. */
  saving: ReadonlySet<string>
  /** `false` when the connection has no REST access. */
  isAvailable: boolean
}

function emptySnapshot(profile?: string): CapabilitiesSnapshot {
  return {
    ...(profile !== undefined ? { profile } : {}),
    lists: {}, errors: {}, loading: new Set(), saving: new Set(), isAvailable: true,
  }
}

function withItem<T>(set: ReadonlySet<T>, item: T, on: boolean): Set<T> {
  const next = new Set(set)
  if (on) next.add(item)
  else next.delete(item)
  return next
}

/** The Capabilities page's lists and switches for one profile. */
export class CapabilitiesBoard extends Observable<CapabilitiesSnapshot> {
  private tokens: Partial<Record<CapabilityKind, number>> = {}

  constructor(private readonly access: GatewayAccess) {
    super(emptySnapshot())
  }

  private update(change: Partial<CapabilitiesSnapshot>): void {
    this.set({ ...this.get(), ...change })
  }

  /** Reads one list of `profile`'s capabilities. Another profile's lists are dropped first. */
  async refresh(kind: CapabilityKind, profile: string): Promise<void> {
    if (this.get().profile !== profile) {
      for (const k of capabilityKinds) this.tokens[k] = (this.tokens[k] ?? 0) + 1
      this.set(emptySnapshot(profile))
    }
    const token = (this.tokens[kind] ?? 0) + 1
    this.tokens[kind] = token
    this.update({ loading: withItem(this.get().loading, kind, true) })
    const current = () => this.tokens[kind] === token && this.get().profile === profile
    try {
      if (kind !== 'plugins' && !this.access.dashboardAPI) {
        this.update({ isAvailable: false })
        return
      }
      const rows = await this.read(kind, profile)
      if (!current()) return
      const errors = { ...this.get().errors }
      delete errors[kind]
      this.update({
        isAvailable: true,
        lists: { ...this.get().lists, [kind]: [...rows].sort((a, b) => standardCompare(a.title, b.title)) },
        errors,
      })
    } catch (error) {
      if (!current()) return
      this.update({ errors: { ...this.get().errors, [kind]: describeError(error) } })
    } finally {
      if (this.tokens[kind] === token) this.update({ loading: withItem(this.get().loading, kind, false) })
    }
  }

  /** Turns a capability on or off. The row flips at once and flips back if the server refuses. */
  async setEnabled(row: Capability, enabled: boolean): Promise<void> {
    const { profile, saving } = this.get()
    const id = capabilityID(row)
    if (profile === undefined || row.lockedReason !== undefined || saving.has(id)) return
    this.update({ saving: withItem(this.get().saving, id, true) })
    this.replace({ ...row, isEnabled: enabled })
    try {
      await this.write(row, enabled, profile)
    } catch (error) {
      if (this.get().profile === profile) this.replace(row)
      throw error
    } finally {
      this.update({ saving: withItem(this.get().saving, id, false) })
    }
  }

  private replace(row: Capability): void {
    const list = this.get().lists[row.kind]
    const index = list?.findIndex((candidate) => candidate.name === row.name) ?? -1
    if (!list || index < 0) return
    const next = [...list]
    next[index] = row
    this.update({ lists: { ...this.get().lists, [row.kind]: next } })
  }

  private async read(kind: CapabilityKind, profile: string): Promise<Capability[]> {
    const rows = (value: JSONValue | undefined, parse: (row: JSONValue) => Capability | undefined) =>
      (arrayOf(value) ?? []).flatMap((row) => parse(row) ?? [])
    if (kind === 'plugins') {
      const answer = await this.access.call('plugins.manage', { action: 'list', profile })
      return rows(field(answer, 'plugins'), pluginCapability)
    }
    const api = this.access.dashboardAPI
    if (!api) throw new GatewayClientError('notConnected')
    switch (kind) {
      case 'skills': return rows(await profileGet(api, '/api/skills', profile), skillCapability)
      case 'toolsets': return rows(await profileGet(api, '/api/tools/toolsets', profile), toolsetCapability)
      case 'mcp': return rows(field(await profileGet(api, '/api/mcp/servers', profile), 'servers'), mcpCapability)
    }
  }

  /**
   * Desktop's switches: `PUT /api/skills/toggle` (`skills.py:379-394`), `PUT
   * /api/tools/toolsets/{name}` (`tools.py:273-335`), `PUT /api/mcp/servers/{name}/enabled`
   * (`mcp.py:372-395`), `plugins.manage` `toggle` by key (`methods_tools.py:1737-1754`).
   */
  private async write(row: Capability, enabled: boolean, profile: string): Promise<void> {
    if (row.kind === 'plugins') {
      const answer = await this.access.call('plugins.manage', { action: 'toggle', key: row.name, enable: enabled, profile })
      if (boolOf(field(answer, 'ok')) === false) {
        throw new RPCError({ code: 5026, message: "The plugin couldn't be switched." })
      }
      return
    }
    const api = this.access.dashboardAPI
    if (!api) throw new GatewayClientError('notConnected')
    const segment = pathSegment(row.name)
    switch (row.kind) {
      case 'skills':
        await profilePut(api, '/api/skills/toggle', profile, { name: row.name, enabled })
        return
      case 'toolsets':
        await profilePut(api, `/api/tools/toolsets/${segment}`, profile, { enabled })
        return
      case 'mcp':
        await profilePut(api, `/api/mcp/servers/${segment}/enabled`, profile, { enabled })
        return
    }
  }
}
