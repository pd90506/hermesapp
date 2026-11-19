import { createContext, useContext, useSyncExternalStore } from 'react'
import type { GatewayConnection, Observable } from '@talaria/hermes-core'
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
 * The connection the window shows (one server's): its chats, lists and link. New code
 * reads it here, so it follows the server the window switches to.
 */
export function useConnection(): GatewayConnection {
  const model = useModel()
  useSnapshot(model)
  return model.connection
}
