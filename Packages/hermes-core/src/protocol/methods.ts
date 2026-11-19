/** Method, event and server-request names (HermesKit's `GatewayMethods.swift`, `ServerRequests.swift`). */
export const GatewayMethod = {
  clientCapabilities: 'client.capabilities',
  gatewayPing: 'gateway.ping',
  sessionList: 'session.list',
  profilesList: 'profiles.list',
  profilesGetAsset: 'profiles.get_asset',
} as const

export const EventType = {
  gatewayReady: 'gateway.ready',
  requestCancel: 'request.cancel',
  sessionsChanged: 'sessions.changed',
} as const

/** The method of event notifications. */
export const eventNotificationMethod = 'event'

export const ServerRequestMethod = {
  /** What a client with approval and clarify cards handles (HermesKit's `mvpSupported`). */
  mvpSupported: new Set(['approval', 'clarify', 'sudo', 'secret']),
  /**
   * Window-owned bridges answered only by a Hermes Desktop window showing the session.
   * Other clients decline them with `notShownCode`: any other error is a final answer
   * that would beat the real window's reply (`tui_gateway/server_requests.py:22-28,221-275`).
   */
  windowOwned: new Set(['preview.read', 'preview.act', 'terminal.read', 'window.read', 'tour']),
  /** `NOT_SHOWN_CODE` (`tui_gateway/server_requests.py:100`). */
  notShownCode: 4404,
} as const

/**
 * The error for a server request this client does not handle: 4404 for window-owned
 * bridges, so a Desktop window sharing the session can still answer; -32601 otherwise,
 * so the agent fails fast (HermesKit's `GatewayClient.decline`).
 */
export function declineServerRequest(method: string): { code: number; message: string } {
  if (ServerRequestMethod.windowOwned.has(method)) {
    return { code: ServerRequestMethod.notShownCode, message: 'not shown in this client' }
  }
  return { code: -32601, message: `unsupported by client: ${method}` }
}
