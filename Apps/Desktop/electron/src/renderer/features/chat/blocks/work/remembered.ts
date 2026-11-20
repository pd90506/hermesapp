import { createContext, useCallback, useContext, useState } from 'react'
import type { ChatSession } from '@talaria/hermes-core'

/**
 * What each fold of a chat was left as (the Mac's `@Remembered`): the virtual list builds
 * a row only near the screen, so a fold the user opened must come back open when its row
 * is built again. Kept per chat, while the chat object lives.
 */
const remembered = new WeakMap<ChatSession, Map<string, unknown>>()

function store(chat: ChatSession): Map<string, unknown> {
  let values = remembered.get(chat)
  if (!values) {
    values = new Map()
    remembered.set(chat, values)
  }
  return values
}

/** The value kept under `key` for the chat, or `initial` until one is set. */
export function useRemembered<T>(chat: ChatSession, key: string, initial: T): [T, (value: T) => void] {
  const values = store(chat)
  const [value, setValue] = useState<T>(() => (values.has(key) ? (values.get(key) as T) : initial))
  const set = useCallback((next: T) => {
    store(chat).set(key, next)
    setValue(next)
  }, [chat, key])
  return [values.has(key) ? (values.get(key) as T) : value, set]
}

/** Reads a kept value without a hook (for a value set from an effect). */
export function rememberedValue<T>(chat: ChatSession, key: string): T | undefined {
  return store(chat).get(key) as T | undefined
}

export function remember(chat: ChatSession, key: string, value: unknown): void {
  store(chat).set(key, value)
}

/**
 * Inside a turn's opened work (the Mac's `isInTurnWork`): its paragraphs have no action
 * bar (the user, 2026-11-12). Package G's action bar reads it with `useIsInTurnWork()`.
 */
export const InTurnWork = createContext(false)

export function useIsInTurnWork(): boolean {
  return useContext(InTurnWork)
}
