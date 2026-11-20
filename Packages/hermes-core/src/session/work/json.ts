import type { JSONValue } from '../../protocol/jsonrpc.ts'

// Small readers over `JSONValue`, as HermesKit's `JSONValue` accessors (`stringValue`,
// `doubleValue`, `arrayValue`), for the tool-call views of package C.

export type JSONRecord = { [key: string]: JSONValue }

export function isRecord(value: JSONValue | undefined): value is JSONRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export const stringValue = (value: JSONValue | undefined): string | undefined =>
  typeof value === 'string' ? value : undefined

export const numberValue = (value: JSONValue | undefined): number | undefined =>
  typeof value === 'number' ? value : undefined

export const arrayValue = (value: JSONValue | undefined): JSONValue[] | undefined =>
  Array.isArray(value) ? value : undefined

/** Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export const trimmed = (text: string): string => text.trim()

/** Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not line breaks. */
export const trimSpaces = (text: string): string => text.replace(/^[^\S\n\r]+|[^\S\n\r]+$/g, '')

/** The text, or undefined when it is empty (Swift's `nonEmpty`). */
export const nonEmpty = (text: string): string | undefined => (text === '' ? undefined : text)

/** Characters as a person counts them (code points, close to Swift's `count`). */
export const length = (text: string): number => {
  let count = 0
  for (const _ of text) count += 1
  return count
}

/** The first `count` characters (code points). */
export function prefix(text: string, count: number): string {
  if (text.length <= count) return text
  return Array.from(text).slice(0, count).join('')
}

/** Parses JSON text; undefined when it is not JSON. */
export function parseJSON(text: string): JSONValue | undefined {
  try {
    return JSON.parse(text) as JSONValue
  } catch {
    return undefined
  }
}

/** Structural equality, for `JSONValue`s compared as values. */
export function jsonEqual(a: JSONValue | undefined, b: JSONValue | undefined): boolean {
  if (a === b) return true
  if (a === undefined || b === undefined || a === null || b === null) return false
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((value, index) => jsonEqual(value, b[index]))
  if (typeof a === 'object') {
    if (typeof b !== 'object' || Array.isArray(b)) return false
    const keys = Object.keys(a)
    return keys.length === Object.keys(b).length && keys.every((key) => key in b && jsonEqual(a[key], b[key]))
  }
  return false
}

/** JSON with sorted keys, as Swift's `JSONEncoder` with `.sortedKeys`. */
export function sortedJSON(value: JSONValue): string {
  if (Array.isArray(value)) return `[${value.map(sortedJSON).join(',')}]`
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${sortedJSON(value[key]!)}`).join(',')}}`
  }
  return JSON.stringify(value)
}
