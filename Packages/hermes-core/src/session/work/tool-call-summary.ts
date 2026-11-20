import type { JSONValue } from '../../protocol/jsonrpc.ts'
import type { TranscriptItem } from '../items.ts'
import { isRecord, length, parseJSON, prefix, stringValue, trimmed, trimSpaces, type JSONRecord } from './json.ts'

/**
 * The words a tool call or a run of them is shown with (HermesKit's `ToolCallSummary`,
 * `ToolRuns.swift`), after Desktop's `tool/run-summary.ts` and `lib/summarize-command.ts`.
 */

type Category = 'edit' | 'explore' | 'search' | 'read' | 'browse' | 'interact' | 'analyze' | 'run' | 'delegate' | 'other'

/** Clause order is fixed, so the same run always reads the same way. */
const categories: readonly Category[] = ['edit', 'explore', 'search', 'read', 'browse', 'interact', 'analyze', 'run', 'delegate', 'other']

const copy: Record<Category, { singular: string; plural: string; past: string; present: string }> = {
  analyze: { singular: 'image', plural: 'images', past: 'Analyzed', present: 'Analyzing' },
  browse: { singular: 'page', plural: 'pages', past: 'Opened', present: 'Opening' },
  delegate: { singular: 'task', plural: 'tasks', past: 'Delegated', present: 'Delegating' },
  edit: { singular: 'file', plural: 'files', past: 'Edited', present: 'Editing' },
  explore: { singular: 'file', plural: 'files', past: 'Explored', present: 'Exploring' },
  interact: { singular: 'browser action', plural: 'browser actions', past: 'Performed', present: 'Performing' },
  other: { singular: 'tool', plural: 'tools', past: 'Used', present: 'Using' },
  read: { singular: 'page', plural: 'pages', past: 'Read', present: 'Reading' },
  run: { singular: 'command', plural: 'commands', past: 'Ran', present: 'Running' },
  search: { singular: 'query', plural: 'queries', past: 'Searched', present: 'Searching' },
}

/** A group row's words for a kind, without a count. */
const groupCopy: Record<Category, { past: string; present: string }> = {
  analyze: { past: 'Analyzed images', present: 'Analyzing images' },
  browse: { past: 'Opened pages', present: 'Opening pages' },
  delegate: { past: 'Delegated tasks', present: 'Delegating tasks' },
  edit: { past: 'Edited files', present: 'Editing files' },
  explore: { past: 'Read files', present: 'Reading files' },
  interact: { past: 'Used the browser', present: 'Using the browser' },
  other: { past: 'Called tools', present: 'Calling tools' },
  read: { past: 'Read pages', present: 'Reading pages' },
  run: { past: 'Ran commands', present: 'Running commands' },
  search: { past: 'Searched', present: 'Searching' },
}

const toolCategories: Record<string, Category> = {
  browser_navigate: 'browse',
  delegate_task: 'delegate',
  execute_code: 'run',
  list_files: 'explore',
  read_file: 'explore',
  search_files: 'explore',
  session_search_recall: 'search',
  terminal: 'run',
  vision_analyze: 'analyze',
  web_extract: 'read',
  web_search: 'search',
}

export const fileEditTools: ReadonlySet<string> = new Set(['edit_file', 'patch', 'write_file'])

/** Tools Desktop draws as their own card, never inside a run (`CARD_TOOL_NAMES`). */
export const cardTools: ReadonlySet<string> = new Set(['clarify', 'delegate_task', 'image_generate', 'manage_catalog',
  'manage_connections', 'set_theme', 'setup_beat'])

function category(name: string): Category {
  if (fileEditTools.has(name)) return 'edit'
  return toolCategories[name] ?? (name.startsWith('browser_') ? 'interact' : 'other')
}

/** The tool a row calls. */
export function toolNameOf(tool: TranscriptItem): string {
  return toolCallOf(tool).name
}

/** The name of Hermes's bridge to deferred tools (`tools/tool_search_catalog.py`, `TOOL_CALL_NAME`). */
export const toolCallBridge = 'tool_call'

/**
 * The call a row stands for. A reloaded transcript keeps the model's own call, so a
 * deferred tool reached through the `tool_call` bridge is stored under the bridge's name
 * with `{name, arguments}` (or `{calls: [...]}`) as its arguments; one inner call stands
 * for itself, as Desktop reads it (`toolPreviewTarget`, `connector-tool.tsx`). A bridge
 * running several calls stays the bridge.
 */
export function unbridgedCall(name: string, args: JSONValue | undefined): { name: string; args: JSONValue | undefined } {
  if (name !== toolCallBridge) return { name, args }
  const record = typeof args === 'string' ? parseJSON(args) : args
  if (!isRecord(record)) return { name, args }
  const calls = Array.isArray(record.calls) ? record.calls : [record]
  if (calls.length !== 1) return { name, args }
  const call = typeof calls[0] === 'string' ? parseJSON(calls[0]) : calls[0]
  const inner = isRecord(call) ? stringValue(call.name)?.trim() : undefined
  if (!inner || !isRecord(call)) return { name, args }
  const innerArgs = typeof call.arguments === 'string' ? parseJSON(call.arguments) : call.arguments
  return { name: inner, args: innerArgs ?? {} }
}

/** A row's tool name and arguments, through the `tool_call` bridge. */
export function toolCallOf(tool: TranscriptItem): { name: string; args: JSONValue | undefined } {
  return unbridgedCall(tool.toolName ?? tool.tool?.name ?? 'tool', tool.tool?.args)
}

/** A row for a file edit (`edit_file`, `patch`, `write_file`). */
export const isFileEdit = (item: TranscriptItem): boolean => item.role === 'tool' && fileEditTools.has(toolNameOf(item))

/** A call Desktop draws as its own card (`isCardTool`, `lib/tool-render-class.ts`). */
export const isCardTool = (item: TranscriptItem): boolean => item.role === 'tool' && cardTools.has(toolNameOf(item))

/** The call's arguments as an object; a JSON-encoded string is decoded. */
export function toolArgs(tool: TranscriptItem): JSONRecord {
  const args = toolCallOf(tool).args
  if (isRecord(args)) return args
  if (typeof args === 'string') {
    const parsed = parseJSON(args)
    return isRecord(parsed) ? parsed : {}
  }
  return {}
}

/** The first of `keys` with text, trimmed; undefined when none. */
export function argString(args: JSONRecord, keys: readonly string[]): string | undefined {
  for (const key of keys) {
    const value = stringValue(args[key])
    if (value !== undefined && trimmed(value) !== '') return trimmed(value)
  }
  return undefined
}

/** The first `http(s)://` string, depth first, keys in order. */
export function firstURLString(value: JSONValue | undefined): string | undefined {
  if (typeof value === 'string') return value.startsWith('http://') || value.startsWith('https://') ? value : undefined
  if (Array.isArray(value)) {
    for (const item of value) {
      const url = firstURLString(item)
      if (url !== undefined) return url
    }
    return undefined
  }
  if (isRecord(value)) {
    for (const key of Object.keys(value).sort()) {
      const url = firstURLString(value[key])
      if (url !== undefined) return url
    }
  }
  return undefined
}

/** "example.com/docs": a URL's host and path. */
export function hostname(url: string): string {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return url
  }
  if (parsed.hostname === '') return url
  let path = parsed.pathname
  try { path = decodeURI(path) } catch { /* keep it encoded */ }
  return path === '' || path === '/' ? parsed.hostname : parsed.hostname + path
}

export function basename(path: string): string {
  const normalized = trimSpaces(path.replace(/\\/g, '/'))
  const parts = normalized.split('/').filter((part) => part !== '')
  return parts[parts.length - 1] ?? normalized
}

function compact(text: string, limit: number): string {
  const line = text.split(/\r\n|\n|\r/).find((part) => part !== '') ?? text
  const shown = trimSpaces(line)
  return length(shown) > limit ? prefix(shown, limit - 1) + '…' : shown
}

export function lowerFirst(text: string): string {
  return text === '' ? text : text[0]!.toLowerCase() + text.slice(1)
}

export const ToolCallSummary = {
  /**
   * The run as one line: one clause per category, skills first, then failures. While
   * `live`, the category of the call in progress (else the newest) speaks in the
   * present tense: "Ran 5 commands, explored 3 files".
   */
  run(tools: readonly TranscriptItem[], live: boolean): string {
    const narrating = live ? (tools.find((tool) => tool.isActive) ?? tools[tools.length - 1]) : undefined
    const liveCategory = narrating ? category(toolNameOf(narrating)) : undefined
    const skills: string[] = []
    const groups = new Map<Category, TranscriptItem[]>()
    for (const tool of tools) {
      const skill = skillTitle(tool, live)
      if (skill !== undefined) skills.push(skill)
      else {
        const kind = category(toolNameOf(tool))
        groups.set(kind, [...(groups.get(kind) ?? []), tool])
      }
    }
    const clauses = [...skills, ...categories.flatMap((kind) => {
      const group = groups.get(kind)
      return group ? [clause(kind, group, kind === liveCategory)] : []
    })]
    const failed = tools.filter((tool) => tool.tool?.phase === 'failed').length
    if (failed > 0) clauses.push(`${failed} tool call${failed === 1 ? '' : 's'} failed`)
    return clauses.map((text, index) => (index === 0 ? text : lowerFirst(text))).join(', ')
  },

  /**
   * A group of steps as its row names it: what its calls did, one clause per kind in
   * the order they came and no counts, three at most and then "etc."; "Analysis
   * completed" for reasoning alone. While `live`, the kind of the call in progress
   * (else the newest) speaks in the present tense.
   */
  groupTitle(tools: readonly TranscriptItem[], live: boolean): string {
    if (tools.length === 0) return live ? 'Analyzing' : 'Analysis completed'
    const narrating = live ? (tools.find((tool) => tool.isActive) ?? tools[tools.length - 1]) : undefined
    const liveCategory = narrating ? category(toolNameOf(narrating)) : undefined
    const order: Category[] = []
    for (const tool of tools) {
      const kind = category(toolNameOf(tool))
      if (!order.includes(kind)) order.push(kind)
    }
    const clauses = order.slice(0, 3).map((kind) => (kind === liveCategory ? groupCopy[kind].present : groupCopy[kind].past))
    if (order.length > 3) clauses.push('etc.')
    return clauses.map((text, index) => (index === 0 ? text : lowerFirst(text))).join(', ')
  },

  /**
   * A unified diff as a diff box shows it: file headers (`diff --git`, `index`, `---`,
   * `+++`) and hunk headers (`@@`) dropped, as Desktop's `parseDiff` drops them.
   */
  displayDiff(diff: string): string {
    return diff.split('\n').filter((line) => !(line.startsWith('diff --git') || line.startsWith('index ')
      || line.startsWith('--- ') || line.startsWith('+++ ') || line === '---' || line === '+++' || line.startsWith('@@'))).join('\n')
  },

  /**
   * The command a wrapped shell line is about, for display only: `cd`, env prefixes,
   * redirects, `| tail` and banner echoes peeled off. Several real commands read as
   * "first + N commands".
   */
  summarizeShellCommand(raw: string): string {
    const original = trimmed(raw)
    if (original === '') return ''
    const segments = splitCompound(original)
    if (segments.length <= 1) {
      const cleaned = clean(original)
      return cleaned === '' ? original : cleaned
    }
    const core = segments.map(clean).filter((segment) => segment !== '' && !silentHeads.has(headWord(segment)) && !isBoundaryEcho(segment))
    if (core.length === 0) return original
    if (core.length === 1) return core[0]!
    return `${core[0]} + ${core.length - 1} ${core.length === 2 ? 'command' : 'commands'}`
  },
} as const

function clause(kind: Category, tools: readonly TranscriptItem[], live: boolean): string {
  const words = copy[kind]
  const verb = live ? words.present : words.past
  const count = tools.reduce((sum, tool) => sum + unitCount(tool), 0)
  const named = count === 1 && kind !== 'interact' ? target(tools[0]!, kind) : ''
  // A settled command reads better as a count: its line only earns the space while it
  // is the thing being waited on.
  if (named !== '' && (live || kind !== 'run')) return `${verb} ${named}`
  return `${verb} ${count} ${count === 1 ? words.singular : words.plural}`
}

function skillTitle(tool: TranscriptItem, live: boolean): string | undefined {
  const name = toolNameOf(tool)
  if (name !== 'skill_view' && name !== 'skills_list') return undefined
  const args = toolArgs(tool)
  const failed = tool.tool?.phase === 'failed'
  const pending = live && tool.isActive
  const file = argString(args, ['file_path'])
  let label: string
  if (name === 'skills_list') label = failed ? 'Failed to list skills' : pending ? 'Listing skills' : 'Listed skills'
  else if (file !== undefined) label = failed ? 'Failed to read skill resource' : pending ? 'Reading skill resource' : 'Read skill resource'
  else label = failed ? 'Failed to load skill' : pending ? 'Loading skill' : 'Loaded skill'
  const named = [argString(args, ['name']), file].filter((part): part is string => part !== undefined).join(' → ')
  return named === '' ? label : `${label}: ${named}`
}

/** The thing a call acted on, as a line names it. */
function target(tool: TranscriptItem, kind: Category): string {
  const args = toolArgs(tool)
  const context = tool.tool?.context ?? tool.detail
  switch (kind) {
    case 'run':
      return compact(ToolCallSummary.summarizeShellCommand(argString(args, ['command', 'code']) ?? context ?? ''), 60)
    case 'search': {
      const query = argString(args, ['query', 'search_term']) ?? context
      return query !== undefined ? `“${compact(query, 48)}”` : ''
    }
    case 'read': case 'browse': {
      const url = firstURLString(args)
      if (url !== undefined) return hostname(url)
      return context !== undefined ? compact(context, 48) : ''
    }
    case 'other':
      return toolNameOf(tool)
    default: {
      const path = argString(args, ['path', 'file', 'filepath'])
      if (path !== undefined) return basename(path)
      const value = argString(args, ['query', 'url']) ?? context
      return value !== undefined ? compact(value, 48) : ''
    }
  }
}

/** `web_extract` takes several URLs: each is a page read. */
function unitCount(tool: TranscriptItem): number {
  if (toolNameOf(tool) !== 'web_extract') return 1
  const urls = toolArgs(tool).urls
  return Array.isArray(urls) && urls.length > 0 ? urls.length : 1
}

// MARK: Shell commands

const silentHeads = new Set(['cd', 'pushd', 'popd', 'export', 'set', 'unset', 'source', '.', 'true', 'false', ':'])
const pipeTailHeads = new Set(['head', 'tail', 'wc', 'sort', 'uniq'])

/** Splits on top-level `&&`, `||`, `;` and newlines, outside quotes; each segment loses its pipe tail. */
function splitCompound(input: string): string[] {
  const segments: string[] = []
  let buffer = ''
  let quote: string | undefined
  let previous: string | undefined
  const characters = Array.from(input)
  let index = 0
  while (index < characters.length) {
    const character = characters[index]!
    if (quote !== undefined) {
      buffer += character
      if (character === quote && previous !== '\\') quote = undefined
      index += 1
      previous = character
      continue
    }
    if (character === '"' || character === "'") {
      quote = character
      buffer += character
      index += 1
      previous = character
      continue
    }
    const next = characters[index + 1]
    if ((character === '&' && next === '&') || (character === '|' && next === '|')) {
      segments.push(buffer)
      buffer = ''
      index += 2
      previous = character
      continue
    }
    if (character === ';' || character === '\n') {
      segments.push(buffer)
      buffer = ''
      index += 1
      previous = character
      continue
    }
    buffer += character
    index += 1
    previous = character
  }
  segments.push(buffer)
  return segments.map((segment) => stripPipeTail(trimSpaces(segment))).filter((segment) => segment !== '')
}

function words(segment: string): string[] {
  const result: string[] = []
  let buffer = ''
  let quote: string | undefined
  let previous: string | undefined
  for (const character of segment) {
    if (quote !== undefined) {
      buffer += character
      if (character === quote && previous !== '\\') quote = undefined
    } else if (character === '"' || character === "'") {
      quote = character
      buffer += character
    } else if (/\s/.test(character)) {
      if (buffer !== '') { result.push(buffer); buffer = '' }
    } else {
      buffer += character
    }
    previous = character
  }
  if (buffer !== '') result.push(buffer)
  return result
}

function commandBasename(head: string): string {
  const parts = head.split('/').filter((part) => part !== '')
  return parts[parts.length - 1] ?? head
}

function headWord(segment: string): string {
  const head = words(segment).find((word) => !/^[A-Za-z_]\w*=/.test(word))
  return commandBasename(head ?? '')
}

function stripPipeTail(segment: string): string {
  const tokens = words(segment)
  const out: string[] = []
  for (let index = 0; index < tokens.length; index += 1) {
    const word = tokens[index]!
    if (word === '|' && index + 1 < tokens.length && pipeTailHeads.has(commandBasename(tokens[index + 1]!))) break
    out.push(word)
  }
  return trimSpaces(out.join(' '))
}

function clean(segment: string): string {
  const out: string[] = []
  let skipNext = false
  for (const word of words(segment)) {
    if (skipNext) { skipNext = false; continue }
    if (/^\d*(>>?|<)$/.test(word)) { skipNext = true; continue }
    if (/^\d*(>&|<&)\d+$/.test(word)) continue
    out.push(word)
  }
  return trimSpaces(out.join(' '))
}

function isBoundaryEcho(segment: string): boolean {
  const tokens = words(segment)
  if (commandBasename(tokens[0] ?? '') !== 'echo') return false
  return /-{2,}|_exit=|(^|\s|=)\$[?{]|PIPESTATUS/.test(tokens.slice(1).join(' '))
}
