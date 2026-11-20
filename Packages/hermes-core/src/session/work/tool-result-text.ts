import type { JSONValue } from '../../protocol/jsonrpc.ts'
import { isRecord, length, parseJSON, prefix, stringValue, trimmed, trimSpaces, type JSONRecord } from './json.ts'

/**
 * A tool result as readable text, and the failure a result reports (HermesKit's
 * `ToolResultText`, after Desktop's `lib/tool-result-summary.ts`). Keys that aren't
 * ranked first are taken in alphabetical order, as on the Mac.
 */
export const ToolResultText = {
  wrapperKeys: ['data', 'result', 'output', 'response', 'payload'] as readonly string[],

  /** The result as a short block: a message, a list of fields, or a list of items. */
  summary(value: JSONValue | undefined): string {
    if (value === undefined) return ''
    const unwrapped = summaryValue(unwrapPayload(value), 0)
    return unwrapped === '' ? summaryValue(value, 0) : unwrapped
  },

  /** The failure the result reports, nested anywhere under an error key, or "". */
  errorMessage(value: JSONValue | undefined): string {
    if (value === undefined) return ''
    return nestedError(value, 0, false)
  },

  isFailureStatus(status: string): boolean {
    return /^(error|failed|failure|fatal|exception)$/i.test(trimSpaces(status))
  },
} as const

const wrapperKeys = ToolResultText.wrapperKeys
const priorityKeys = ['title', 'name', 'path', 'file', 'filepath', 'url', 'href', 'link', 'status', 'id',
  'message', 'summary', 'description']
const errorKeys = ['error', 'errors', 'failure', 'exception']
const errorMessageKeys = ['message', 'reason', 'detail']
const nonErrorText = new Set(['', '0', 'false', 'none', 'null', 'nil', 'ok', 'success', 'n/a', 'na'])

/** A string holding JSON (an object, an array or a quoted string) as that JSON. */
function norm(value: JSONValue): JSONValue {
  if (typeof value !== 'string') return value
  const text = trimmed(value)
  if (text === '') return ''
  if (!(text.startsWith('{') || text.startsWith('[') || text.startsWith('"'))) return value
  return parseJSON(text) ?? value
}

export function unwrapPayload(value: JSONValue): JSONValue {
  let current = norm(value)
  for (let step = 0; step < 4; step += 1) {
    if (!isRecord(current)) return current
    const record: JSONRecord = current
    const key = wrapperKeys.find((candidate) => record[candidate] !== undefined && record[candidate] !== null)
    if (key === undefined) return current
    current = norm(record[key]!)
  }
  return current
}

export function capitalize(text: string): string {
  return text === '' ? text : text[0]!.toUpperCase() + text.slice(1)
}

function titleCase(key: string): string {
  return key.split(/[_\-.]/).filter((part) => part !== '').map(capitalize).join(' ')
}

const pluralize = (count: number, noun: string) => `${count} ${noun}${count === 1 ? '' : 's'}`

function clipInline(value: string, max = 180): string {
  const line = trimSpaces(value.replace(/\s+/g, ' '))
  return length(line) > max ? prefix(line, max - 1) + '…' : line
}

function clipBlock(value: string, maxCharacters = 1800, maxLines = 18): string {
  const text = trimmed(value)
  if (text === '') return ''
  const lines = text.split('\n')
  let shown = lines.slice(0, maxLines).join('\n')
  const clipped = lines.length > maxLines || length(shown) > maxCharacters
  if (length(shown) > maxCharacters) shown = prefix(shown, maxCharacters - 1).replace(/\s+$/, '')
  return clipped && !shown.endsWith('…') ? shown + '…' : shown
}

/** The first of `keys` holding text that isn't blank, trimmed; "" when none does. */
export function firstString(record: JSONRecord, keys: readonly string[]): string {
  for (const key of keys) {
    const value = stringValue(record[key])
    if (value !== undefined && trimmed(value) !== '') return trimmed(value)
  }
  return ''
}

/** A number as JSON writes it: whole numbers without a point. */
export function numberText(value: JSONValue | undefined): string {
  if (typeof value !== 'number') return ''
  return Number.isInteger(value) && Math.abs(value) < 1e15 ? String(value) : String(value)
}

function orderedKeys(keys: readonly string[]): string[] {
  return [...priorityKeys.filter((key) => keys.includes(key)), ...keys.filter((key) => !priorityKeys.includes(key)).sort()]
}

const isWrapperKey = (key: string) => wrapperKeys.includes(key)

const skipField = (key: string, value: JSONValue | undefined) =>
  isWrapperKey(key) || ((key === 'success' || key === 'ok') && value === true)

function scalar(value: JSONValue): string {
  if (typeof value === 'string') return clipInline(value)
  if (typeof value === 'number') return numberText(value)
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  return ''
}

function recordInline(record: JSONRecord, depth: number): string {
  const count = Object.keys(record).length
  if (depth > 3) return pluralize(count, 'field')
  const title = firstString(record, ['title', 'name', 'path', 'file', 'filepath', 'url', 'href', 'link', 'id'])
  const status = firstString(record, ['status', 'category', 'type'])
  const message = firstString(record, ['snippet', 'summary', 'description', 'message'])
  if (title !== '' && status !== '') return `${clipInline(title, 110)} (${clipInline(status, 54)})`
  if (title !== '' && message !== '' && title !== message) return `${clipInline(title, 90)} - ${clipInline(message, 84)}`
  if (title !== '') return clipInline(title, 150)
  const pairs = orderedKeys(Object.keys(record)).filter((key) => !skipField(key, record[key])).flatMap((key) => {
    const text = scalar(record[key]!)
    return text === '' ? [] : [`${titleCase(key)}: ${text}`]
  }).slice(0, 2)
  return pairs.length === 0 ? pluralize(count, 'field') : pairs.join(' · ')
}

function listItem(item: JSONValue, depth: number): string {
  const value = norm(item)
  if (typeof value === 'string') return clipInline(value)
  if (typeof value === 'number' || typeof value === 'boolean') return scalar(value)
  if (value === null) return ''
  if (Array.isArray(value)) return pluralize(value.length, 'item')
  return recordInline(value, depth + 1)
}

function fieldValue(raw: JSONValue, depth: number): string {
  const value = norm(raw)
  const text = scalar(value)
  if (text !== '') return text
  if (Array.isArray(value)) {
    if (value.length === 0) return ''
    const scalars = value.map(scalar).filter((part) => part !== '')
    if (scalars.length === value.length && value.length <= 4) return clipInline(scalars.join(', '))
    const first = listItem(value[0]!, depth + 1)
    return first === '' ? pluralize(value.length, 'item') : `${pluralize(value.length, 'item')} (${first})`
  }
  if (isRecord(value)) return recordInline(value, depth + 1)
  return ''
}

function arraySummary(values: JSONValue[], depth: number): string {
  if (values.length === 0) return ''
  const max = 6
  const lines = values.slice(0, max).map((value) => listItem(value, depth + 1)).filter((line) => line !== '').map((line) => `- ${line}`)
  if (lines.length === 0) return ''
  if (values.length > max) {
    const remaining = values.length - max
    lines.push(`- … ${remaining} more ${remaining === 1 ? 'item' : 'items'}`)
  }
  return lines.join('\n')
}

function recordSummary(record: JSONRecord, depth: number): string {
  const keys = Object.keys(record)
  if (keys.length === 0) return ''
  if (depth <= 2) {
    const direct = firstString(record, ['message', 'summary', 'description', 'preview', 'text', 'content'])
    const meaningful = keys.filter((key) => !skipField(key, record[key]) && !isWrapperKey(key))
    if (direct !== '' && meaningful.length <= 1) return clipBlock(direct)
  }
  const candidates = orderedKeys(keys).filter((key) => !skipField(key, record[key]))
  const lines: string[] = []
  for (const key of candidates) {
    const text = fieldValue(record[key]!, depth + 1)
    if (text === '') continue
    lines.push(`- ${titleCase(key)}: ${text}`)
    if (lines.length >= 8) break
  }
  if (lines.length === 0) return ''
  if (candidates.length > lines.length) {
    const remaining = candidates.length - lines.length
    lines.push(`- … ${remaining} more ${remaining === 1 ? 'field' : 'fields'}`)
  }
  return lines.join('\n')
}

function summaryValue(raw: JSONValue, depth: number): string {
  if (depth > 4) return ''
  const value = norm(raw)
  if (typeof value === 'string') return clipBlock(value)
  if (typeof value === 'number' || typeof value === 'boolean') return scalar(value)
  if (value === null) return ''
  if (Array.isArray(value)) return arraySummary(value, depth + 1)
  return recordSummary(value, depth + 1)
}

// MARK: Errors

function meaningfulError(raw: JSONValue | undefined): boolean {
  if (raw === undefined) return false
  const value = norm(raw)
  if (value === null) return false
  if (typeof value === 'string') return !nonErrorText.has(trimSpaces(value).toLowerCase())
  if (typeof value === 'boolean') return value
  if (typeof value === 'number') return value !== 0
  if (Array.isArray(value)) return value.some((item) => meaningfulError(item))
  return Object.keys(value).length > 0
}

function errorSignal(record: JSONRecord): boolean {
  const status = stringValue(record.status) ?? ''
  return record.success === false || record.ok === false || ToolResultText.isFailureStatus(status)
    || errorKeys.some((key) => meaningfulError(record[key]))
}

function valueErrorText(raw: JSONValue): string {
  const value = norm(raw)
  if (typeof value === 'string') return meaningfulError(value) ? clipBlock(value, 700, 12) : ''
  if (Array.isArray(value)) {
    const texts = value.map(valueErrorText).filter((text) => text !== '').slice(0, 3)
    return clipBlock(texts.join('; '), 700, 12)
  }
  if (isRecord(value)) {
    const direct = firstString(value, errorMessageKeys)
    return direct === '' ? '' : clipBlock(direct, 700, 12)
  }
  return ''
}

function nestedError(raw: JSONValue, depth: number, failed: boolean): string {
  if (depth > 5) return ''
  const value = norm(raw)
  if (Array.isArray(value)) {
    for (const item of value) {
      const nested = nestedError(item, depth + 1, failed)
      if (nested !== '') return nested
    }
    return ''
  }
  if (!isRecord(value)) return ''
  if (value.success === true || value.ok === true) return ''
  for (const key of errorKeys) {
    if (!meaningfulError(value[key])) continue
    const text = valueErrorText(value[key]!)
    if (text !== '') return text
  }
  if (errorSignal(value)) {
    const direct = firstString(value, errorMessageKeys)
    if (direct !== '') return clipBlock(direct, 700, 12)
  }
  // Returned data and stdout can describe failures without the tool failing. Only
  // unwrap them to explain a failure already declared by the envelope.
  const declared = failed || errorSignal(value)
  const keys = declared ? [...errorKeys, ...wrapperKeys, 'details'] : errorKeys
  for (const key of keys) {
    const child = value[key]
    if (child === undefined) continue
    const nested = nestedError(child, depth + 1, declared)
    if (nested !== '') return nested
  }
  return ''
}
