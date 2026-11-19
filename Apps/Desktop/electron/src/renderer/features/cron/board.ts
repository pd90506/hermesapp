import { useEffect } from 'react'
import { CronBoard, DashboardCronSource, type GatewayConnection } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'

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
    const board = new CronBoard({
      listProfile: () => connection.get().selectedProfile,
      modelOptions: (profile) => connection.call('model.options', profile ? { profile } : {}),
    })
    // The connector's REST routes as they are at each call: a reconnect or another
    // sign-in replaces them.
    const source = new DashboardCronSource({
      send: (method, path, options) => {
        const api = connection.dashboardAPI
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
    board.setSource(connection.dashboardAPI ? source : undefined)
  }, [board, source, connection, link])
  return { board, connection }
}
