import { DashboardClient, DashboardError } from './dashboard.ts'
import type { GatewayEndpoint } from './endpoint.ts'
import type { HttpClient, MessageTransport } from './http.ts'

/**
 * How the app authenticates to the dashboard WebSocket
 * (`hermes_cli/web_server_chat.py::_ws_auth_reason`; HermesKit's `GatewayCredential`).
 * A browser sign-in (native PKCE) comes in a later change.
 */
export type GatewayCredential =
  /** A password provider (e.g. `basic`): cookie sign-in, then a ticket per connect. */
  | { kind: 'password'; provider: string; username: string; password: string }
  /** An access token: a ticket minted with `Authorization: Bearer` per connect. */
  | { kind: 'bearer'; accessToken: string }
  /**
   * A token sent as `/api/ws?token=`: a provider access token on a gated dashboard, or
   * the session token of an un-gated loopback one. Long-lived and in the URL; prefer
   * `bearer`.
   */
  | { kind: 'sessionToken'; token: string }

/** Produces a fresh, authenticated transport for each connection attempt. */
export interface GatewayConnector {
  makeTransport(): Promise<MessageTransport>
}

/** `GatewayConnector` for the dashboard's `/api/ws` (HermesKit's `DashboardConnector`). */
export class DashboardConnector implements GatewayConnector {
  readonly dashboard: DashboardClient

  constructor(
    readonly endpoint: GatewayEndpoint,
    readonly credential: GatewayCredential,
    http: HttpClient,
    private readonly openSocket: (url: string) => MessageTransport,
  ) {
    this.dashboard = new DashboardClient(endpoint, http)
  }

  async makeTransport(): Promise<MessageTransport> {
    return this.openSocket(await this.webSocketURL())
  }

  /** The upgrade URL. A ticket goes in `?ticket=`, as Hermes Desktop sends it. */
  async webSocketURL(): Promise<string> {
    const credential = this.credential
    switch (credential.kind) {
      case 'sessionToken':
        return this.endpoint.webSocketURL([['token', credential.token]])
      case 'bearer': {
        const ticket = await this.dashboard.mintWebSocketTicket(credential.accessToken)
        return this.endpoint.webSocketURL([['ticket', ticket.ticket]])
      }
      case 'password': {
        let ticket
        try {
          // The cookie session, while it lasts (the server renews it from its refresh cookie).
          ticket = await this.dashboard.mintWebSocketTicket()
        } catch (error) {
          if (!(error instanceof DashboardError && error.kind === 'unauthenticated')) throw error
          await this.dashboard.passwordLogin(credential.provider, credential.username, credential.password)
          ticket = await this.dashboard.mintWebSocketTicket()
        }
        return this.endpoint.webSocketURL([['ticket', ticket.ticket]])
      }
    }
  }
}
