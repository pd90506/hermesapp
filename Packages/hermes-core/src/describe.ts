import { GatewayClientError } from './client.ts'
import { DashboardError } from './dashboard.ts'
import { EndpointError } from './endpoint.ts'
import { TransportError } from './http.ts'
import { RPCError } from './protocol/jsonrpc.ts'

/**
 * A short user-facing message, as HermesKit's `GatewayConnection.describe`. Never
 * includes a request URL: a `?token=` credential could be in it.
 */
export function describeError(error: unknown): string {
  if (error instanceof RPCError) return error.message
  if (error instanceof DashboardError) {
    switch (error.kind) {
      case 'unauthenticated': return 'Not signed in, or the session expired.'
      case 'invalidCredentials': return 'Username or password was rejected.'
      case 'rateLimited': return 'Too many login attempts; wait a minute.'
      case 'http': return `The dashboard answered HTTP ${error.status}.`
      case 'invalidResponse': return 'The dashboard sent an answer this app could not read.'
    }
  }
  if (error instanceof TransportError) {
    if (error.kind === 'handshakeFailed') {
      // The gateway rejects bad tickets or tokens AND host/origin mismatches before
      // accepting, which shows as a bare HTTP 403 on the upgrade.
      return `The gateway refused the WebSocket (expired ticket/token or host check): ${error.message}`
    }
    return error.message
  }
  if (error instanceof GatewayClientError) {
    switch (error.kind) {
      case 'readyTimeout': return 'The gateway did not respond.'
      case 'connectionClosed': return 'The connection to the gateway was lost.'
      case 'notConnected': return 'Not connected to the gateway.'
      case 'timeout': return 'The gateway did not answer in time.'
      case 'heartbeatTimeout': return 'The gateway stopped answering.'
      default: return error.message
    }
  }
  if (error instanceof EndpointError) return error.message
  return error instanceof Error ? error.message : String(error)
}
