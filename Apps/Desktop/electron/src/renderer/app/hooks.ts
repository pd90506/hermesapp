import { createContext, useContext, useSyncExternalStore } from 'react'
import type { ConnectionSnapshot, GatewayConnection, Observable, ServersSnapshot } from '@talaria/hermes-core'
import type { AppModel } from './model.ts'

export const ModelContext = createContext<AppModel | null>(null)

export function useModel(): AppModel {
  const model = useContext(ModelContext)
  if (!model) throw new Error('useModel outside ModelContext')
  return model
}

export function useSnapshot<T>(observable: Observable<T>): T {
  return useSyncExternalStore(observable.subscribe, observable.get)
}

/**
 * The current server's connection (the server of the profile picked in the rail), and
 * a re-render whenever it changes: another server picked, or its snapshot (K). Use this
 * rather than `useSnapshot(model.connection)`, which misses a change of server.
 */
export function useConnection(): GatewayConnection {
  const model = useModel()
  useSnapshot(model)
  const connection = model.connection
  useSnapshot(connection)
  return connection
}

/** The current server's connection snapshot (see `useConnection`). */
export function useConnectionSnapshot(): ConnectionSnapshot {
  return useConnection().get()
}

/** The servers and their states (`ServerRegistry`). */
export function useServers(): ServersSnapshot {
  return useSnapshot(useModel().servers)
}
