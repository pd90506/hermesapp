import { DashboardClient } from '../dashboard.ts'
import type { GatewayEndpoint } from '../endpoint.ts'
import type { HttpClient } from '../http.ts'
import { exchangeNativeCode, type NativeTokens } from './native-tokens.ts'
import { makePKCE, randomState, type PKCE } from './pkce.ts'

/** The path the browser comes back to. */
export const nativeCallbackPath = '/callback'

export class NativeSignInError extends Error {
  constructor(readonly kind: 'stateMismatch' | 'noCode' | 'refused', detail?: string) {
    super(detail ?? (kind === 'stateMismatch' ? 'Another page answered the sign-in.' : 'The sign-in sent no code.'))
  }
}

/**
 * One browser sign-in (HermesKit's `NativeSignIn`; RFC 8252: the system browser, a
 * loopback redirect and PKCE), as Hermes Desktop signs in to a remote gateway. The main
 * process listens on `127.0.0.1:<port>`, the browser opens `authorizeURL`, and the URL it
 * comes back to goes to `tokens(from:)` (`hermes_cli/dashboard_auth/routes.py:269-314,499-516`).
 */
export class NativeSignIn {
  readonly pkce: PKCE
  readonly state: string
  /** `http://127.0.0.1:<port>/callback`: the server takes only a loopback IP literal over HTTP (`routes.py:241-274`). */
  readonly redirectURI: string
  private readonly dashboard: DashboardClient

  constructor(endpoint: GatewayEndpoint, port: number, http: HttpClient,
    pkce: PKCE = makePKCE(), state: string = randomState()) {
    this.pkce = pkce
    this.state = state
    this.redirectURI = `http://127.0.0.1:${port}${nativeCallbackPath}`
    this.dashboard = new DashboardClient(endpoint, http)
  }

  /** The page to open. No provider: the server picks its only one or shows a chooser (`routes.py:277-285`). */
  get authorizeURL(): string {
    return this.dashboard.endpoint.urlFor('/auth/native/authorize', [
      ['code_challenge', this.pkce.challenge],
      ['code_challenge_method', 'S256'],
      ['redirect_uri', this.redirectURI],
      ['state', this.state],
    ])
  }

  /** The code in the redirect, once its `state` is this sign-in's. */
  code(callback: string): string {
    const query = new URL(callback, 'http://127.0.0.1').searchParams
    const error = query.get('error')
    if (error) throw new NativeSignInError('refused', query.get('error_description') ?? error)
    if (query.get('state') !== this.state) throw new NativeSignInError('stateMismatch')
    const code = query.get('code')
    if (!code) throw new NativeSignInError('noCode')
    return code
  }

  /** The token pair for the redirect. The code is spent even when this fails. */
  tokens(callback: string): Promise<NativeTokens> {
    return exchangeNativeCode(this.dashboard, this.code(callback), this.pkce.verifier)
  }
}

/** Whether a request the loopback listener got (a path with its query) is the redirect, not a favicon. */
export function isNativeCallback(target: string): boolean {
  return new URL(target, 'http://127.0.0.1').pathname === nativeCallbackPath
}
