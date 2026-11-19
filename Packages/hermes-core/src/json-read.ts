import type { JSONValue } from './protocol/jsonrpc.ts'

/** Lenient readers for dashboard answers: a missing or mistyped field reads as undefined. */
export type JSONObject = { [key: string]: JSONValue }

export function objectOf(value: JSONValue | undefined): JSONObject | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : undefined
}

export function arrayOf(value: JSONValue | undefined): JSONValue[] | undefined {
  return Array.isArray(value) ? value : undefined
}

export function stringOf(value: JSONValue | undefined): string | undefined {
  return typeof value === 'string' ? value : undefined
}

/** A string that isn't empty. */
export function textOf(value: JSONValue | undefined): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

export function boolOf(value: JSONValue | undefined): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined
}

export function field(value: JSONValue | undefined, key: string): JSONValue | undefined {
  return objectOf(value)?.[key]
}

/** Finder's order (`localizedStandardCompare`): case-insensitive, numbers by value. */
export function standardCompare(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' })
}

/** Finder's search (`localizedStandardContains`): case- and diacritic-insensitive. */
export function standardContains(text: string, words: string): boolean {
  const fold = (s: string) => s.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLocaleLowerCase()
  return fold(text).includes(fold(words))
}
