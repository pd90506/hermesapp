import {
  pathSegment, profileDelete, profileGet, profilePost, profilePut, requestStatus,
  type DashboardAPI, type GatewayAccess,
} from '../dashboard-api.ts'
import { describeError } from '../describe.ts'
import { GatewayClientError } from '../client.ts'
import { DashboardError } from '../dashboard.ts'
import {
  arrayOf, boolOf, field, objectOf, standardCompare, standardContains, stringOf, textOf,
} from '../json-read.ts'
import { Observable } from '../observable.ts'
import type { JSONValue } from '../protocol/jsonrpc.ts'

/**
 * One credential or setting in a profile's `.env`, from `GET /api/env?profile=`
 * (`hermes_cli/web_routers/config_env.py:259-325`). Values never come back, only whether
 * one is set and a redacted preview. HermesKit's `ProviderEnvVar`.
 */
export interface ProviderEnvVar {
  key: string
  isSet: boolean
  redactedValue?: string
  description: string
  url?: string
  isPassword: boolean
  isAdvanced: boolean
}

/** A key, rather than a URL or a region (`isKeyVar`, `apps/desktop/src/app/settings/credential-key-ui.tsx:28`). */
export function isKeyVar(variable: ProviderEnvVar): boolean {
  const key = variable.key
  return variable.isPassword || key.endsWith('_API_KEY') || key.endsWith('_TOKEN') || key.endsWith('_KEY')
}

/**
 * A provider's card on the API Keys page: its main key, then its other settings (base
 * URL, region), as Desktop groups them (`buildProviderKeyGroups`, `providers-settings.tsx:74-144`).
 */
export interface ProviderKeyGroup {
  name: string
  description: string
  docsURL?: string
  primary: ProviderEnvVar
  others: ProviderEnvVar[]
  hasAnySet: boolean
}

function label(labelValue: JSONValue | undefined, provider: JSONValue | undefined): string {
  const text = stringOf(labelValue)?.trim() ?? ''
  return text === '' ? stringOf(provider)?.trim() ?? '' : text
}

/**
 * The `provider` category rows of `GET /api/env`, by the catalog's provider label. A
 * credential that serves several providers (`provider_profiles`) is on each one's card;
 * rows with no provider label are left out, as Desktop's "Other" bucket is. Providers
 * with a key set first, then by name.
 */
export function providerKeyGroups(env: JSONValue): ProviderKeyGroup[] {
  const buckets = new Map<string, Array<{ variable: ProviderEnvVar; primary: boolean }>>()
  const entries = Object.entries(objectOf(env) ?? {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
  for (const [key, info] of entries) {
    if (stringOf(field(info, 'category')) !== 'provider') continue
    const base: ProviderEnvVar = {
      key,
      isSet: boolOf(field(info, 'is_set')) ?? false,
      description: stringOf(field(info, 'description')) ?? '',
      isPassword: boolOf(field(info, 'is_password')) ?? false,
      isAdvanced: boolOf(field(info, 'advanced')) ?? false,
    }
    const redacted = stringOf(field(info, 'redacted_value'))
    if (redacted !== undefined) base.redactedValue = redacted
    const url = stringOf(field(info, 'url'))
    if (url !== undefined) base.url = url
    const scoped: Array<{ name: string; variable: ProviderEnvVar; primary: boolean }> = []
    const profiles = arrayOf(field(info, 'provider_profiles'))
    if (profiles && profiles.length > 0) {
      for (const profile of profiles) {
        const variable = { ...base }
        const text = textOf(field(profile, 'description'))
        if (text) variable.description = text
        const profileURL = stringOf(field(profile, 'url'))
        if (profileURL !== undefined) variable.url = profileURL
        scoped.push({ name: label(field(profile, 'provider_label'), field(profile, 'provider')), variable,
          primary: boolOf(field(profile, 'primary')) ?? false })
      }
    } else {
      scoped.push({ name: label(field(info, 'provider_label'), field(info, 'provider')), variable: base,
        primary: boolOf(field(info, 'provider_primary')) ?? false })
    }
    for (const entry of scoped) {
      if (entry.name === '') continue
      const bucket = buckets.get(entry.name) ?? []
      bucket.push({ variable: entry.variable, primary: entry.primary })
      buckets.set(entry.name, bucket)
    }
  }
  const groups: ProviderKeyGroup[] = []
  for (const [name, bucket] of buckets) {
    const primary = bucket.find((e) => e.primary && isKeyVar(e.variable))?.variable
      ?? bucket.find((e) => !e.variable.isAdvanced && isKeyVar(e.variable))?.variable
      ?? bucket.find((e) => isKeyVar(e.variable))?.variable
    if (!primary) continue
    // Alias keys (ANTHROPIC_TOKEN beside ANTHROPIC_API_KEY) only show while set, so they
    // stay removable; no second "paste a key" field.
    const others = bucket.map((e) => e.variable)
      .filter((v) => v.key !== primary.key && (!isKeyVar(v) || v.isSet))
      .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
    const group: ProviderKeyGroup = {
      name, description: primary.description, primary, others,
      hasAnySet: primary.isSet || others.some((v) => v.isSet),
    }
    if (primary.url !== undefined) group.docsURL = primary.url
    groups.push(group)
  }
  return groups.sort((a, b) => (a.hasAnySet !== b.hasAnySet ? (a.hasAnySet ? -1 : 1) : standardCompare(a.name, b.name)))
}

/** The groups whose name, description or keys hold `query` (the API Keys page's search). */
export function filterKeyGroups(groups: readonly ProviderKeyGroup[], query: string): readonly ProviderKeyGroup[] {
  const words = query.trim()
  if (words === '') return groups
  return groups.filter((group) =>
    [group.name, group.description, group.primary.key, ...group.others.map((v) => v.key)]
      .some((text) => standardContains(text, words)))
}

/**
 * A sign-in provider on the Accounts page, from `GET /api/providers/oauth?profile=`
 * (`hermes_cli/web_routers/oauth.py:671-690`).
 */
export interface ProviderAccount {
  id: string
  name: string
  /** `device_code` signs in from here; `external` is signed in with its own CLI. */
  flow: string
  cliCommand?: string
  docsURL?: string
  isSignedIn: boolean
  /** Nous Portal's free tier counts as not connected (`providers-settings.tsx:185`). */
  isFreeTier: boolean
  /** Where the credential is from (`Nous Portal`, `~/.codex/auth.json`). */
  sourceLabel?: string
  tokenPreview?: string
  canDisconnect: boolean
  /** Why it can't be disconnected from here. */
  disconnectHint?: string
}

export function accountIsConnected(account: ProviderAccount): boolean {
  return account.isSignedIn && !account.isFreeTier
}

export function accountSignsInHere(account: ProviderAccount): boolean {
  return account.flow === 'device_code'
}

/** The line under an account's name (`ProvidersView.accountStatus`). */
export function accountStatus(account: ProviderAccount): string {
  if (accountIsConnected(account)) {
    return ['Connected', account.sourceLabel, account.tokenPreview].filter((s) => s !== undefined).join(' · ')
  }
  if (account.isFreeTier) return 'Free tier · sign in for your account'
  if (!accountSignsInHere(account) && account.cliCommand) return `Sign in on the server: ${account.cliCommand}`
  return 'Not connected'
}

export function providerAccount(json: JSONValue): ProviderAccount | undefined {
  const id = textOf(field(json, 'id'))
  if (!id) return undefined
  const status = field(json, 'status')
  const account: ProviderAccount = {
    id,
    name: textOf(field(json, 'name')) ?? id,
    flow: textOf(field(json, 'flow')) ?? 'external',
    isSignedIn: boolOf(field(status, 'logged_in')) ?? false,
    isFreeTier: boolOf(field(status, 'free_tier')) ?? false,
    canDisconnect: boolOf(field(json, 'disconnectable')) ?? false,
  }
  const optional: Array<[keyof ProviderAccount, string | undefined]> = [
    ['cliCommand', textOf(field(json, 'cli_command'))],
    ['docsURL', textOf(field(json, 'docs_url'))],
    ['sourceLabel', textOf(field(status, 'source_label'))],
    ['tokenPreview', textOf(field(status, 'token_preview'))],
    ['disconnectHint', textOf(field(json, 'disconnect_hint'))],
  ]
  for (const [key, value] of optional) if (value !== undefined) (account as unknown as Record<string, unknown>)[key] = value
  return account
}

/**
 * A device-code sign-in in progress: the code to enter at the provider's page
 * (`POST /api/providers/oauth/{id}/start`, `oauth.py:144-155,794-844`).
 */
export interface ProviderSignIn {
  provider: string
  providerName: string
  sessionID: string
  userCode: string
  verificationURL?: string
  status: { phase: 'waiting' } | { phase: 'approved' } | { phase: 'failed'; reason: string }
}

/**
 * An OpenAI-compatible endpoint the profile can use as a provider, from `GET
 * /api/providers/custom-endpoints?profile=` (`config_env.py:450-462,728-738`).
 */
export interface CustomEndpoint {
  id: string
  name: string
  baseURL: string
  model: string
  models: string[]
  hasAPIKey: boolean
  apiKeyPreview?: string
  /** The profile's default model runs on it. */
  isCurrent: boolean
}

export function customEndpoint(json: JSONValue): CustomEndpoint | undefined {
  const id = stringOf(field(json, 'id'))
  const baseURL = stringOf(field(json, 'base_url'))
  if (id === undefined || baseURL === undefined) return undefined
  const endpoint: CustomEndpoint = {
    id,
    name: stringOf(field(json, 'name')) ?? id,
    baseURL,
    model: stringOf(field(json, 'model')) ?? '',
    models: (arrayOf(field(json, 'models')) ?? []).flatMap((m) => (typeof m === 'string' ? [m] : [])),
    hasAPIKey: boolOf(field(json, 'has_api_key')) ?? false,
    isCurrent: boolOf(field(json, 'is_current')) ?? false,
  }
  const preview = stringOf(field(json, 'api_key_preview'))
  if (preview !== undefined) endpoint.apiKeyPreview = preview
  return endpoint
}

/** The New Endpoint form (`CustomEndpointUpdate`, `hermes_cli/web_models.py:46-58`). */
export interface CustomEndpointDraft {
  name: string
  baseURL: string
  model: string
  apiKey: string
  makeDefault: boolean
}

export function emptyEndpointDraft(): CustomEndpointDraft {
  return { name: '', baseURL: '', model: '', apiKey: '', makeDefault: false }
}

export function endpointDraftCanSave(draft: CustomEndpointDraft): boolean {
  return [draft.name, draft.baseURL, draft.model].every((s) => s.trim() !== '')
}

export function endpointDraftBody(draft: CustomEndpointDraft): JSONValue {
  const body: { [key: string]: JSONValue } = {
    name: draft.name.trim(),
    base_url: draft.baseURL.trim(),
    model: draft.model.trim(),
    make_default: draft.makeDefault,
  }
  const key = draft.apiKey.trim()
  if (key !== '') body.api_key = key
  return body
}

/** What the Providers page shows for one profile (HermesKit's `ProvidersBoard`). */
export interface ProvidersSnapshot {
  profile?: string
  keyGroups: readonly ProviderKeyGroup[]
  accounts: readonly ProviderAccount[]
  endpoints: readonly CustomEndpoint[]
  /** The profile's default model and its provider (`custom-endpoints`' `current`). */
  currentModel?: string
  currentProvider?: string
  isLoading: boolean
  hasLoaded: boolean
  error?: string
  /** `false` when the connection has no REST access. */
  isAvailable: boolean
  /** The sign-in on show, until it's dismissed. */
  signIn?: ProviderSignIn
  /** Rows being saved: env keys, account ids, endpoint ids. */
  saving: ReadonlySet<string>
}

function emptySnapshot(profile?: string): ProvidersSnapshot {
  return {
    ...(profile !== undefined ? { profile } : {}),
    keyGroups: [], accounts: [], endpoints: [],
    isLoading: false, hasLoaded: false, isAvailable: true, saving: new Set(),
  }
}

export interface ProvidersBoardOptions {
  /** Wait after a failed poll before the next; 2 s as HermesKit. */
  pollRetryDelayMs?: number
}

/**
 * The Providers page's state and actions for one profile: reads keys, accounts and
 * endpoints; saves and removes keys; signs in with a device code; adds, activates and
 * deletes endpoints. Every write is followed by a fresh read.
 */
export class ProvidersBoard extends Observable<ProvidersSnapshot> {
  private token = 0
  private signInRun = 0
  private readonly retryDelayMs: number

  constructor(private readonly access: GatewayAccess, options: ProvidersBoardOptions = {}) {
    super(emptySnapshot())
    this.retryDelayMs = options.pollRetryDelayMs ?? 2000
  }

  private update(change: Partial<ProvidersSnapshot>): void {
    this.set({ ...this.get(), ...change })
  }

  private savingWith(id: string, on: boolean): void {
    const saving = new Set(this.get().saving)
    if (on) saving.add(id)
    else saving.delete(id)
    this.update({ saving })
  }

  /** Reads `profile`'s keys, accounts and endpoints. Another profile's are dropped first. */
  async refresh(profile: string): Promise<void> {
    if (this.get().profile !== profile) {
      this.token += 1
      this.cancelSignIn()
      this.set(emptySnapshot(profile))
    }
    const api = this.access.dashboardAPI
    if (!api) {
      this.update({ isAvailable: false })
      return
    }
    const token = ++this.token
    this.update({ isAvailable: true, isLoading: true })
    // Accounts and endpoints are best effort, as in Desktop: a failure hides the section.
    const env = profileGet(api, '/api/env', profile)
    const accounts = profileGet(api, '/api/providers/oauth', profile).catch(() => undefined)
    const endpoints = profileGet(api, '/api/providers/custom-endpoints', profile).catch(() => undefined)
    try {
      const groups = providerKeyGroups(await env)
      const [accountRows, endpointRows] = await Promise.all([accounts, endpoints])
      if (token !== this.token || this.get().profile !== profile) return
      const change: Partial<ProvidersSnapshot> = { keyGroups: groups, hasLoaded: true, isLoading: false }
      if (accountRows !== undefined) {
        change.accounts = (arrayOf(field(accountRows, 'providers')) ?? []).flatMap((row) => providerAccount(row) ?? [])
      }
      const next = { ...this.get(), ...change }
      delete next.error
      if (endpointRows !== undefined) {
        next.endpoints = (arrayOf(field(endpointRows, 'endpoints')) ?? []).flatMap((row) => customEndpoint(row) ?? [])
        const current = field(endpointRows, 'current')
        const model = textOf(field(current, 'model'))
        const provider = textOf(field(current, 'provider'))
        delete next.currentModel
        delete next.currentProvider
        if (model) next.currentModel = model
        if (provider) next.currentProvider = provider
      }
      this.set(next)
    } catch (error) {
      if (token !== this.token || this.get().profile !== profile) return
      this.update({ error: describeError(error), hasLoaded: true, isLoading: false })
    }
  }

  /** Saves a key to the profile's `.env` (`PUT /api/env`, `config_env.py:328-339`), which also replaces any stale copy of it in `config.yaml`. */
  setKey(key: string, value: string): Promise<void> {
    return this.change(key, (api, profile) =>
      profilePut(api, '/api/env', profile, { key, value: value.trim(), provider_setup: true }))
  }

  /** Removes a key and every copy of it (`DELETE /api/env`, `config_env.py:1067-1082`). */
  removeKey(key: string): Promise<void> {
    return this.change(key, (api, profile) => profileDelete(api, '/api/env', profile, { key }))
  }

  /** Signs out of a provider (`DELETE /api/providers/oauth/{id}`, `oauth.py:727-777`). */
  disconnect(account: ProviderAccount): Promise<void> {
    return this.change(account.id, (api, profile) =>
      profileDelete(api, `/api/providers/oauth/${pathSegment(account.id)}`, profile))
  }

  /** Adds an endpoint (`POST /api/providers/custom-endpoints`, `config_env.py:741-769`). */
  addEndpoint(draft: CustomEndpointDraft): Promise<void> {
    return this.change('endpoint:new', (api, profile) =>
      profilePost(api, '/api/providers/custom-endpoints', profile, endpointDraftBody(draft)))
  }

  /** Makes an endpoint the profile's default provider (`config_env.py:772-821`). */
  activateEndpoint(endpoint: CustomEndpoint): Promise<void> {
    return this.change(endpoint.id, (api, profile) =>
      profilePost(api, `/api/providers/custom-endpoints/${pathSegment(endpoint.id)}/activate`, profile))
  }

  deleteEndpoint(endpoint: CustomEndpoint): Promise<void> {
    return this.change(endpoint.id, (api, profile) =>
      profileDelete(api, `/api/providers/custom-endpoints/${pathSegment(endpoint.id)}`, profile))
  }

  /**
   * Starts a device-code sign-in and waits for it in the background: `signIn` shows the
   * code to enter, and turns approved or failed (`oauth.py:794-905`). The session is the
   * server's, so the code works from any browser.
   */
  async startSignIn(account: ProviderAccount): Promise<void> {
    const profile = this.get().profile
    const api = this.access.dashboardAPI
    if (profile === undefined || !api) throw new GatewayClientError('notConnected')
    this.cancelSignIn()
    this.savingWith(account.id, true)
    let start: JSONValue
    try {
      start = await profilePost(api, `/api/providers/oauth/${pathSegment(account.id)}/start`, profile)
    } finally {
      this.savingWith(account.id, false)
    }
    const sessionID = stringOf(field(start, 'session_id'))
    if (!sessionID) throw new DashboardError('invalidResponse', undefined, 'no sign-in session')
    const signIn: ProviderSignIn = {
      provider: account.id, providerName: account.name, sessionID,
      userCode: stringOf(field(start, 'user_code')) ?? '', status: { phase: 'waiting' },
    }
    const verification = stringOf(field(start, 'verification_url'))
    if (verification) signIn.verificationURL = verification
    this.update({ signIn })
    const run = ++this.signInRun
    void this.waitForSignIn(signIn, profile, api, run)
  }

  /** Stops waiting and drops the server's sign-in session. */
  cancelSignIn(): void {
    this.signInRun += 1
    const { signIn, profile } = this.get()
    if (!signIn) return
    const next = { ...this.get() }
    delete next.signIn
    this.set(next)
    const api = this.access.dashboardAPI
    if (signIn.status.phase !== 'waiting' || !api || profile === undefined) return
    void profileDelete(api, `/api/providers/oauth/sessions/${pathSegment(signIn.sessionID)}`, profile).catch(() => {})
  }

  /** Long-polls until the session leaves `pending` (the route waits up to 25 s each time). */
  private async waitForSignIn(signIn: ProviderSignIn, profile: string, api: DashboardAPI, run: number): Promise<void> {
    const path = `/api/providers/oauth/${pathSegment(signIn.provider)}/poll/${pathSegment(signIn.sessionID)}`
    let failures = 0
    while (run === this.signInRun) {
      let answer: JSONValue
      try {
        answer = await profileGet(api, path, profile, [['wait', '25']], 40_000)
        failures = 0
      } catch (error) {
        if (run !== this.signInRun) return
        failures += 1
        if (failures >= 3 || requestStatus(error) === 404) {
          this.finishSignIn(signIn, { phase: 'failed', reason: describeError(error) })
          return
        }
        await new Promise<void>((resolve) => setTimeout(resolve, this.retryDelayMs))
        continue
      }
      if (run !== this.signInRun) return
      const status = stringOf(field(answer, 'status')) ?? 'pending'
      if (status === 'pending') continue
      if (status === 'approved') {
        this.finishSignIn(signIn, { phase: 'approved' })
        await this.refresh(profile)
      } else {
        this.finishSignIn(signIn, {
          phase: 'failed', reason: textOf(field(answer, 'error_message')) ?? "The sign-in didn't finish.",
        })
      }
      return
    }
  }

  private finishSignIn(signIn: ProviderSignIn, status: ProviderSignIn['status']): void {
    const current = this.get().signIn
    if (current?.sessionID !== signIn.sessionID) return
    this.update({ signIn: { ...current, status } })
  }

  /** One write, then a fresh read of the page. */
  private async change(id: string, write: (api: DashboardAPI, profile: string) => Promise<unknown>): Promise<void> {
    const profile = this.get().profile
    const api = this.access.dashboardAPI
    if (profile === undefined || !api) throw new GatewayClientError('notConnected')
    this.savingWith(id, true)
    try {
      await write(api, profile)
    } finally {
      this.savingWith(id, false)
    }
    await this.refresh(profile)
  }
}
