import { DashboardError, type DashboardClient } from '../dashboard.ts'

/**
 * A browser sign-in's token pair, from `/auth/native/token` and `/auth/native/refresh`
 * (`hermes_cli/dashboard_auth/routes.py:499-547`), as the server sends it. Kept as the
 * server's secret in this JSON shape, the same as HermesKit's `NativeTokens.secret`.
 */
export interface NativeTokens {
  access_token: string
  refresh_token: string
  token_type?: string
  /** Unix seconds. */
  expires_at?: number
  provider?: string
  user_id?: string
}

/** The pair as the app keeps it: one secret. */
export function nativeTokensSecret(tokens: NativeTokens): string {
  return JSON.stringify(tokens)
}

/** A pair kept as a secret, or undefined when it isn't one. */
export function nativeTokensFromSecret(secret: string): NativeTokens | undefined {
  try {
    const value = JSON.parse(secret) as Partial<NativeTokens>
    if (typeof value?.access_token !== 'string' || value.access_token === '') return undefined
    return {
      ...value,
      access_token: value.access_token,
      refresh_token: typeof value.refresh_token === 'string' ? value.refresh_token : '',
    }
  } catch {
    return undefined
  }
}

/** `POST /auth/native/token`: trades a sign-in's code for a pair. The code is spent even on failure. */
export function exchangeNativeCode(dashboard: DashboardClient, code: string, verifier: string): Promise<NativeTokens> {
  return dashboard.send({
    method: 'POST',
    url: dashboard.endpoint.urlFor('/auth/native/token'),
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code, code_verifier: verifier }),
  })
}

/** The reason a rejected refresh token is reported with: the user has to sign in again. */
export const refreshRejectedReason = 'refresh_rejected'

/**
 * `POST /auth/native/refresh`: a new pair; the old refresh token must not be used again.
 * A rejected refresh token throws `DashboardError('unauthenticated')` with
 * `refreshRejectedReason`, which ends reconnecting (`GatewayConnection`).
 */
export async function refreshNativeTokens(dashboard: DashboardClient, refreshToken: string, provider: string):
  Promise<NativeTokens> {
  try {
    return await dashboard.send({
      method: 'POST',
      url: dashboard.endpoint.urlFor('/auth/native/refresh'),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refreshToken, provider }),
    })
  } catch (error) {
    if (error instanceof DashboardError && error.kind === 'unauthenticated') {
      throw new DashboardError('unauthenticated', 401, refreshRejectedReason)
    }
    throw error
  }
}

/**
 * The current pair for one server (HermesKit's `NativeTokenSession`), refreshed when the
 * access token expires. One per server for the app's life, so every connect shares it;
 * `onRotate` gets each new pair (to save it) before any request uses it.
 *
 * Refreshes are single-flight: callers that saw the same rejected access token share one
 * `/auth/native/refresh`. Replaying a rotated refresh token is fatal on providers with
 * reuse detection, and Hermes only coalesces same-token refreshes for 30 s
 * (`hermes_cli/dashboard_auth/refresh_singleflight.py:1-11,24-29`).
 */
export class NativeTokenSession {
  private inFlight?: Promise<NativeTokens>

  constructor(
    private current: NativeTokens,
    private readonly onRotate: (tokens: NativeTokens) => Promise<void> | void = () => {},
    private readonly refreshMarginSeconds = 60,
    private readonly now: () => number = () => Date.now() / 1000,
  ) {}

  get tokens(): NativeTokens {
    return this.current
  }

  /** An access token to use now, refreshed first when it is known to be expired. */
  async accessToken(dashboard: DashboardClient): Promise<{ token: string; refreshed: boolean }> {
    const expiresAt = this.current.expires_at
    if (expiresAt !== undefined && this.now() >= expiresAt - this.refreshMarginSeconds) {
      return { token: await this.refresh(this.current.access_token, dashboard), refreshed: true }
    }
    return { token: this.current.access_token, refreshed: false }
  }

  /** Replaces `rejected` with a fresh access token; if another caller already did, returns it. */
  async refresh(rejected: string, dashboard: DashboardClient): Promise<string> {
    if (this.current.access_token !== rejected) return this.current.access_token
    if (this.inFlight) return (await this.inFlight).access_token
    const old = this.current
    if (!old.refresh_token) throw new DashboardError('unauthenticated', 401, refreshRejectedReason)
    const task = (async () => {
      const fresh = await refreshNativeTokens(dashboard, old.refresh_token, old.provider ?? '')
      const kept = fresh.provider ? fresh : { ...fresh, provider: old.provider }
      await this.onRotate(kept)
      return kept
    })()
    this.inFlight = task
    try {
      const fresh = await task
      this.current = fresh
      return fresh.access_token
    } finally {
      this.inFlight = undefined
    }
  }
}
