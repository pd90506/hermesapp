import type { GatewayCredential } from '../connector.ts'
import { defaultServerName } from '../endpoint.ts'
import { NativeTokenSession, nativeTokensFromSecret } from './native-tokens.ts'

/**
 * How the app signs in to a dashboard (HermesKit's `AuthMode`). Maps 1:1 onto
 * `GatewayCredential`; `browser` keeps the token pair of a browser sign-in as its secret.
 */
export type AuthMode = 'password' | 'browser' | 'accessToken' | 'sessionToken'

export const authModes: readonly AuthMode[] = ['password', 'browser', 'accessToken', 'sessionToken']

/** The settings' words for each mode (HermesKit's `AuthMode.label`, `secretLabel`, `help`). */
export const authModeCopy: Record<AuthMode, { label: string; secretLabel: string; help?: string }> = {
  password: { label: 'Username & password', secretLabel: 'Password' },
  browser: {
    label: 'Sign in with browser',
    secretLabel: 'Sign-in',
    help: 'Sign in on the dashboard’s own page, in the browser. The sign-in then renews itself, so it lasts until the server revokes it (30 days unused for basic).',
  },
  accessToken: {
    label: 'Access token (ticket)',
    secretLabel: 'Access token',
    help: 'A dashboard access token. The app exchanges it for a single-use ticket on every connect.',
  },
  sessionToken: {
    label: 'Token in URL (?token=)',
    secretLabel: 'Token',
    help: 'Sent directly in the WebSocket URL. Works with an access token, or with the session token of a loopback-only dashboard (reachable from another device only through a tunnel). Prefer the other modes.',
  },
}

/**
 * One Hermes dashboard the app connects to (HermesKit's `ServerConfig`). Non-secret and
 * saved in settings.json; the password or token is kept apart, encrypted by the OS.
 */
export interface ServerConfig {
  /** Never changes; names the server's secret and its kept state. */
  id: string
  /** The user's name for it; empty means "derive one from the URL". */
  name: string
  serverURL: string
  authMode: AuthMode
  provider: string
  username: string
}

/** A blank server (the settings' Add Server). */
export function newServerConfig(id: string, change: Partial<Omit<ServerConfig, 'id'>> = {}): ServerConfig {
  return { id, name: '', serverURL: '', authMode: 'password', provider: 'basic', username: '', ...change }
}

/** Reads a saved server, tolerating fields added later or dropped (HermesKit's decoder). */
export function decodeServerConfig(value: unknown, makeID: () => string): ServerConfig | undefined {
  if (!value || typeof value !== 'object') return undefined
  const raw = value as Record<string, unknown>
  const text = (key: string, fallback = '') => (typeof raw[key] === 'string' ? raw[key] as string : fallback)
  const mode = raw.authMode
  return {
    id: text('id') || makeID(),
    name: text('name'),
    serverURL: text('serverURL'),
    authMode: authModes.includes(mode as AuthMode) ? mode as AuthMode : 'password',
    provider: text('provider', 'basic'),
    username: text('username'),
  }
}

/** The name, or one derived from the URL (`hermes` for `hermes.example.ts.net`). */
export function serverDisplayName(config: Pick<ServerConfig, 'name' | 'serverURL'>): string {
  const trimmed = config.name.trim()
  if (trimmed) return trimmed
  return defaultServerName(config.serverURL) ?? 'New Server'
}

/** Whether there is anything to connect to. */
export function hasServerURL(config: Pick<ServerConfig, 'serverURL'>): boolean {
  return config.serverURL.trim() !== ''
}

/**
 * The credential for a saved server. A browser sign-in's is made by `ServerRegistry`,
 * which keeps one token session per server (`NativeTokenSession`); here it is a fresh one.
 */
export function serverCredential(config: ServerConfig, secret: string): GatewayCredential {
  switch (config.authMode) {
    case 'password':
      return { kind: 'password', provider: config.provider || 'basic', username: config.username, password: secret }
    case 'accessToken': return { kind: 'bearer', accessToken: secret }
    case 'sessionToken': return { kind: 'sessionToken', token: secret }
    case 'browser': {
      const tokens = nativeTokensFromSecret(secret) ?? { access_token: '', refresh_token: '' }
      return { kind: 'native', session: new NativeTokenSession(tokens) }
    }
  }
}

/**
 * The saved servers, or the single server of the first desktop version (`server` in
 * settings.json, its secret in `server-secret.bin`), which becomes the first of the list.
 * A saved list wins even when empty: the user removed every server.
 */
export function loadServerList(settings: { servers?: unknown; server?: unknown }, makeID: () => string):
  { servers: ServerConfig[]; migrated?: ServerConfig } {
  if (Array.isArray(settings.servers)) {
    const servers = settings.servers.map((item) => decodeServerConfig(item, makeID))
      .filter((item): item is ServerConfig => item !== undefined)
    return { servers }
  }
  const legacy = decodeServerConfig(settings.server, makeID)
  if (!legacy || !hasServerURL(legacy)) return { servers: [] }
  return { servers: [legacy], migrated: legacy }
}
