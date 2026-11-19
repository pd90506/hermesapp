import { useEffect } from 'react'
import {
  CronBoard, DashboardCronSource, type CronHTTP, type GatewayConnection, type JSONValue,
} from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'

/**
 * The connection's REST access and gateway calls (`GatewayConnection.dashboardAPI` and
 * `call`, which the Providers package adds to hermes-core). Read by shape, so this tab
 * builds before and after that lands; without them the tab says it can't read jobs.
 */
interface CronCapableConnection {
  readonly dashboardAPI?: CronHTTP | undefined
  call?: (method: string, params?: JSONValue) => Promise<unknown>
}

interface Entry {
  board: CronBoard
  source: DashboardCronSource
}

const entries = new WeakMap<GatewayConnection, Entry>()

/** One board per connection, kept as long as the connection (HermesKit's `GatewayConnection.cron`). */
export function cronBoard(connection: GatewayConnection): CronBoard {
  return entry(connection).board
}

function entry(connection: GatewayConnection): Entry {
  let found = entries.get(connection)
  if (!found) {
    const capable = connection as unknown as CronCapableConnection
    const board = new CronBoard({
      listProfile: () => connection.get().selectedProfile,
      modelOptions: (profile) => {
        if (!capable.call) return Promise.reject(new Error('Not connected to the gateway.'))
        return capable.call('model.options', profile ? { profile } : {})
      },
    })
    // The connector's REST routes as they are at each call: a reconnect or another
    // sign-in replaces them.
    const source = new DashboardCronSource({
      send: (method, path, options) => {
        const api = capable.dashboardAPI
        return api ? api.send(method, path, options) : Promise.reject(new Error('Not connected to the gateway.'))
      },
    })
    found = { board, source }
    entries.set(connection, found)
  }
  return found
}

/** The current connection's board; it reads jobs while the connection has REST access. */
export function useCronBoard(): { board: CronBoard; connection: GatewayConnection } {
  const connection = useModel().connection
  const link = useSnapshot(connection).link.phase
  const { board, source } = entry(connection)
  useEffect(() => {
    if (link !== 'connected') return
    const hasREST = (connection as unknown as CronCapableConnection).dashboardAPI !== undefined
    board.setSource(hasREST ? source : undefined)
  }, [board, source, connection, link])
  return { board, connection }
}
