import type { JSONValue } from '../protocol/jsonrpc.ts'
import {
  attachmentDisplayName, makeItem, splitImageDirectives, splitLeadingAttachmentRefs, storedImages, userTurn,
  type ToolActivity, type TranscriptItem, type TranscriptRole,
} from './items.ts'
import type { StoredMessage } from './types.ts'

/** Tool name and arguments by call id, carried from an assistant row to its tool rows. */
export type ToolCalls = Map<string, { name: string; args: Record<string, JSONValue> }>

/**
 * Stored rows of `GET /api/sessions/{id}/messages` as display rows (HermesKit's
 * `StoredMessageProjection`, after `_history_to_messages`,
 * `tui_gateway/session_history.py:285-362`):
 * - only `user`, `assistant`, `tool` and `system` rows, never `hidden` ones (the session's
 *   opening prompt excepted, as Desktop keeps it), never a `[System: …]` user notice;
 * - `display_content` replaces `content`;
 * - an assistant row with neither text nor reasoning is skipped; its tool calls name the
 *   tool rows that follow it.
 */
export function storedItems(rows: readonly StoredMessage[], toolCalls: ToolCalls, startsSession = false): TranscriptItem[] {
  const items: TranscriptItem[] = []
  const opening = startsSession ? rows.findIndex((row) => row.role === 'user') : -1
  rows.forEach((row, index) => {
    if (row.display_kind === 'hidden' && index !== opening) return
    const text = displayText(row)
    switch (row.role) {
      case 'user': {
        if (text.replace(/^[ \t]+/, '').startsWith('[System:')) return
        const turn = userTurn(text)
        const { caption, paths: directives } = splitImageDirectives(userDisplayText(turn.text))
        const paths = [...directives, ...turn.imagePaths]
        const { text: body, refs } = splitLeadingAttachmentRefs(caption)
        if (body.trim() === '' && paths.length === 0 && refs.length === 0) return
        items.push({
          ...item(row, 'user', body),
          images: storedImages(paths),
          attachments: refs.map(attachmentDisplayName),
          attachmentPaths: refs,
          ...(row.display_kind ? { displayKind: row.display_kind } : {}),
        })
        return
      }
      case 'assistant': {
        for (const call of asArray(row.tool_calls)) {
          const id = stringAt(call, 'id')
          const name = stringAt(objectAt(call, 'function'), 'name')
          if (!id || !name) continue
          toolCalls.set(id, { name, args: toolArguments(objectAt(call, 'function')?.arguments) })
        }
        const reasoning = row.reasoning ?? row.reasoning_content ?? ''
        if (text.trim() === '' && reasoning === '') return
        items.push({ ...item(row, 'assistant', text), reasoning })
        return
      }
      case 'tool': {
        const call = row.tool_call_id ? toolCalls.get(row.tool_call_id) : undefined
        const name = call?.name ?? row.tool_name ?? 'tool'
        const detail = call ? preview(call.args) : undefined
        const activity: ToolActivity = { toolID: row.tool_call_id ?? rowItemID(row), name, phase: 'complete' }
        if (detail !== undefined) activity.context = detail
        if (call && Object.keys(call.args).length > 0) activity.args = call.args
        const output = textOf(row.content)
        if (output !== undefined) activity.output = output
        activity.result = storedResult(row.content)
        items.push({
          ...item(row, 'tool', ''),
          toolName: name,
          ...(detail !== undefined ? { detail } : {}),
          ...(row.tool_call_id ? { toolCallID: row.tool_call_id } : {}),
          tool: activity,
        })
        return
      }
      case 'system':
        if (text.trim() === '') return
        items.push(item(row, 'system', text))
        return
      default:
        return
    }
  })
  return items
}

let unnamedRows = 0

export function rowItemID(row: StoredMessage): string {
  if (typeof row.id === 'number') return `row-${row.id}`
  unnamedRows += 1
  return `row-unnamed-${unnamedRows}`
}

function item(row: StoredMessage, role: TranscriptRole, text: string): TranscriptItem {
  const base = makeItem(rowItemID(row), role, text)
  return {
    ...base,
    ...(typeof row.id === 'number' ? { rowID: row.id } : {}),
    ...(typeof row.timestamp === 'number' ? { timestamp: row.timestamp * 1000 } : {}),
  }
}

/** A stored tool row's content as its result (`parseStoredToolResult`). */
export function storedResult(content: JSONValue | undefined): JSONValue {
  if (content === undefined || content === null) return {}
  if (typeof content === 'string') {
    if (content.trim() === '') return ''
    try { return JSON.parse(content) as JSONValue } catch { return content }
  }
  return content
}

// MARK: User text

const discordNote = /(^|\n)\[Triggering message id: `[^`\n]*` — use as `message_id` for reply\/react\/pin via the discord tools\.\]\n*/g

/** User text as `_history_to_messages` shows it: Discord notes out, a skill turn as typed. */
export function userDisplayText(text: string): string {
  const stripped = text.includes('[Triggering message id: `') ? text.replace(discordNote, '$1') : text
  return skillInvocation(stripped) ?? stripped
}

const invocationPrefix = '[IMPORTANT: The user has invoked the '
const singleSkillMarker = 'The full skill content is loaded below.]'
const singleSkillInstruction = 'The user has provided the following instruction alongside the skill invocation: '
const runtimeNote = '\n\n[Runtime note:'
const bundleMarker = ' skill bundle,'
const bundleInstruction = '\nUser instruction: '
const bundleFirstSkillBlock = '\n\n[Loaded as part of the '
const autoLoadPrefix = '[IMPORTANT: The "'
const skillDirNoteEnd = 'then run them with the terminal tool using the absolute path.'
const excerptJoint = '\u001E'

/** `describe_skill_invocation` (`agent/skill_commands.py:144-171`). */
export function skillInvocation(content: string): string | undefined {
  if (content.startsWith(autoLoadPrefix)) return autoLoadedSkillTurn(content)
  if (!content.startsWith(invocationPrefix)) return undefined
  const afterPrefix = content.slice(invocationPrefix.length)
  let name = ''
  if (afterPrefix.startsWith('"')) {
    const close = afterPrefix.indexOf('"', 1)
    if (close > 0) name = afterPrefix.slice(1, close).trim()
  }
  const label = name.startsWith('/') ? name : `/${name}`
  let instruction: string | undefined
  if (content.includes(bundleMarker)) instruction = cut(content, bundleInstruction, bundleFirstSkillBlock, false)
  else if (content.includes(singleSkillMarker)) instruction = cut(content, singleSkillInstruction, runtimeNote, true)
  if (instruction !== undefined) {
    const words = (instruction.split(excerptJoint)[0] ?? '').split(/\s+/).filter(Boolean).join(' ')
    if (words !== '') return name === '' ? words : `${label} ${words}`
  }
  return name === '' ? undefined : label
}

function autoLoadedSkillTurn(content: string): string | undefined {
  const afterPrefix = content.slice(autoLoadPrefix.length)
  const quote = afterPrefix.indexOf('"')
  const name = quote >= 0 ? afterPrefix.slice(0, quote) : ''
  const bare = name === '' ? undefined : `/${name}`
  const footer = content.lastIndexOf(skillDirNoteEnd)
  if (footer < 0) return bare
  const words = content.slice(footer + skillDirNoteEnd.length).split(/\s+/).filter(Boolean).join(' ')
  return words === '' ? bare : words
}

function cut(content: string, marker: string, stop: string, last: boolean): string | undefined {
  const at = last ? content.lastIndexOf(marker) : content.indexOf(marker)
  if (at < 0) return undefined
  const tail = content.slice(at + marker.length)
  const end = tail.indexOf(stop)
  const trimmed = (end >= 0 ? tail.slice(0, end) : tail).trim()
  return trimmed === '' ? undefined : trimmed
}

/** `display_content`, else `content`: a string, or the text of its parts. */
export function displayText(row: StoredMessage): string {
  return textOf(row.display_content) ?? textOf(row.content) ?? ''
}

export function textOf(value: JSONValue | undefined): string | undefined {
  if (typeof value === 'string') return value
  if (Array.isArray(value)) {
    return value.flatMap((part): string[] => {
      if (typeof part === 'string') return [part]
      const text = stringAt(part, 'text')
      if (text !== undefined) return [text]
      const type = stringAt(part, 'type')
      if (type !== undefined && type.includes('image')) return ['[image]']
      return []
    }).join('\n')
  }
  return undefined
}

export function toolArguments(value: JSONValue | undefined): Record<string, JSONValue> {
  if (isObject(value)) return value
  if (typeof value === 'string') {
    try {
      const decoded = JSON.parse(value) as unknown
      return isObject(decoded) ? decoded as Record<string, JSONValue> : {}
    } catch { return {} }
  }
  return {}
}

/** A short argument preview, at most 80 characters like the gateway's. */
export function preview(args: Record<string, JSONValue>): string | undefined {
  const preferred = ['command', 'path', 'file_path', 'url', 'query', 'pattern', 'name', 'code']
  let value: string | undefined
  for (const key of preferred) if (typeof args[key] === 'string') { value = args[key] as string; break }
  if (value === undefined) {
    for (const key of Object.keys(args).sort()) if (typeof args[key] === 'string') { value = args[key] as string; break }
  }
  if (value === undefined) return undefined
  const line = value.split(/\r?\n|\r/).find((part) => part !== '') ?? value
  const chars = [...line]
  return chars.length > 80 ? chars.slice(0, 77).join('') + '...' : line
}

export function isObject(value: unknown): value is Record<string, JSONValue> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function asArray(value: JSONValue | undefined): JSONValue[] {
  return Array.isArray(value) ? value : []
}

export function objectAt(value: JSONValue | undefined, key: string): Record<string, JSONValue> | undefined {
  if (!isObject(value)) return undefined
  const inner = value[key]
  return isObject(inner) ? inner : undefined
}

export function stringAt(value: JSONValue | undefined, key: string): string | undefined {
  if (!isObject(value)) return undefined
  const inner = value[key]
  return typeof inner === 'string' ? inner : undefined
}
