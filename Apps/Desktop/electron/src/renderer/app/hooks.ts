import { createContext, useContext, useSyncExternalStore } from 'react'
import type { Observable } from '@talaria/hermes-core'
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
