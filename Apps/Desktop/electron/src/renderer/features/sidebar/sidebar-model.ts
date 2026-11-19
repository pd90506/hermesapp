import { DashboardConnector, SessionSidebar, restSender, type GatewayConnection } from '@talaria/hermes-core'
import type { TalariaBridge } from '../../../shared/bridge.ts'

/**
 * The sidebar's state above the connection (`SessionSidebar`), kept in `sidebar.json`
 * through the bridge. `connector` is the connected server's, for the dashboard's REST
 * reads (row activity, read sync, search).
 * TODO: switch `rest` to `connection.dashboardAPI` once dashboard-api.ts lands.
 */
export function createSessionSidebar(bridge: TalariaBridge, connection: GatewayConnection,
  current: () => { connector?: DashboardConnector; serverKey?: string }): SessionSidebar {
  return new SessionSidebar({
    connection,
    rest: () => {
      const connector = current().connector
      return connector ? restSender(connector) : undefined
    },
    serverKey: () => current().serverKey,
    store: { load: () => bridge.sidebar.load(), save: (value) => void bridge.sidebar.save(value).catch(() => {}) },
  })
}
