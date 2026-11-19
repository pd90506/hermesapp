import type { JSONValue } from '../../protocol/jsonrpc.ts'
import type { ToolActivity, TranscriptItem } from '../items.ts'
import {
  arrayValue, isRecord, jsonEqual, length, nonEmpty, numberValue, parseJSON, prefix, sortedJSON, stringValue, trimmed,
  trimSpaces, type JSONRecord,
} from './json.ts'
import { basename, fileEditTools, hostname, ToolCallSummary } from './tool-call-summary.ts'
import { capitalize, firstString, numberText, ToolResultText, unwrapPayload } from './tool-result-text.ts'

export type ToolCallStatus =
  | 'running' | 'success' | 'error'
  /** Routine and expected: a guessed path that wasn't there, `grep` finding nothing. */
  | 'notice'
  /** A call with no result to show, or a refused memory write. */
  | 'warning'

export interface SearchHit { title: string; url: string; snippet: string }

/**
 * How one tool call is drawn: its title, status, counts and what it opens to
 * (HermesKit's `ToolCallView`, after Desktop's `buildToolView` in
 * `components/assistant-ui/tool/fallback-model/index.ts` and its `ToolEntry`).
 *
 * Each tool reads its own fields: `read_file` is "Read notes.md L237-259" and opens to
 * the lines it read, `terminal` is "Ran git status" and opens to `$ git status` and its
 * output, `web_search` opens to its hits. Unknown tools fall back to a readable summary.
 */
export interface ToolCallView {
  toolName: string
  title: string
  status: ToolCallStatus
  isPending: boolean
  isFileEdit: boolean
  /** A line under the title: a path, a query, a first line of output. */
  subtitle: string
  /** What the call opens to: the file's lines, the command's output, a summary. */
  detail: string
  /** A heading over `detail` ("Error details"), or "". */
  detailLabel: string
  /** "3 results", "12 files"; undefined while pending or for an error. */
  countLabel?: string
  durationLabel?: string
  /** An edit's diff, without its "┊ review diff" heading. */
  inlineDiff: string
  searchQuery?: string
  searchHits: SearchHit[]
  /** A command's streams, when the backend reported them apart. */
  stdout?: string
  stderr?: string
  /** `terminal`: the command, shown as `$ command` above its output. */
  terminalCommand?: string
  terminalExitCode?: number
}

interface Part {
  name: string
  args: JSONValue | undefined
  result: JSONValue | undefined
  isPending: boolean
  isError: boolean
  metadata: JSONRecord
}

/** The view of a tool row. */
export function toolCallView(item: TranscriptItem): ToolCallView {
  const tool = item.tool
  const name = item.toolName ?? tool?.name ?? 'tool'
  // Before its arguments arrive, a call is known by the gateway's preview of them.
  let args = tool?.args
  const context = tool?.context ?? item.detail
  if (Object.keys(record(args)).length === 0 && context !== undefined && context !== '') args = { context }
  return buildToolCallView({
    name, args, result: tool ? toolResult(tool) : undefined, isPending: item.isActive,
    isError: tool?.phase === 'failed', metadata: toolMetadata(tool),
  })
}

/** Builds the view from a call's parts (`ToolCallView.init(name:args:result:…)`). */
export function buildToolCallView(part: Part): ToolCallView {
  const { name, args, result, isPending } = part
  const argsRecord = record(args)
  const resultRecord: JSONRecord = { ...part.metadata, ...record(result) }
  const status = statusOf(part, resultRecord)
  const error = status === 'success' ? '' : errorText(part, resultRecord)
  const meta = metaOf(name)
  const memoryMissed = name === 'memory' && result !== undefined && status !== 'success'
  const baseTitle = result === undefined ? meta.pending : memoryMissed ? 'Memory write noted' : meta.done
  const unavailable = result === undefined && !isPending
  const title = unavailable ? 'Result unavailable' : dynamicTitle(part, argsRecord, resultRecord) ?? baseTitle
  const baseSubtitle = error === '' ? subtitleOf(part, argsRecord, resultRecord) : error
  const keepsSubtitle = name === 'terminal' || name === 'execute_code' || (fileEditTools.has(name) && trimmed(baseSubtitle) !== '')
  const detailBody = stripDividerLines(detailText(part, argsRecord, resultRecord))
  const unique: string[] = []
  for (const value of [error, detailBody]) {
    if (value !== '' && !unique.some((seen) => trimmed(seen) === trimmed(value))) unique.push(value)
  }
  const rendersAnsi = name === 'terminal' || name === 'execute_code'
  const stdout = rendersAnsi ? firstString(resultRecord, ['stdout']) : ''
  const stderr = rendersAnsi ? firstString(resultRecord, ['stderr']) : ''
  const splitStreams = rendersAnsi && (stdout !== '' || stderr !== '')
  const query = name === 'web_search' ? nonEmpty(firstString(argsRecord, ['search_term', 'query'])) ?? contextValue(args) : ''
  const seconds = numberOf(resultRecord.duration_s)
  const durationLabel = seconds === undefined || seconds < 0 ? undefined : nonEmpty(duration(seconds))
  const exit = numberValue(resultRecord.exit_code)
  const count = status === 'error' ? undefined : resultCount(part, argsRecord, resultRecord)

  const view: ToolCallView = {
    toolName: name,
    title,
    status,
    isPending,
    isFileEdit: fileEditTools.has(name),
    subtitle: title !== baseTitle && error === '' && !keepsSubtitle ? '' : baseSubtitle,
    detail: error === '' ? detailBody : unique.join('\n\n'),
    detailLabel: error === '' ? (name === 'web_search' ? 'Details' : name === 'browser_snapshot' ? 'Snapshot summary' : '') : 'Error details',
    inlineDiff: inlineDiff(resultRecord),
    searchHits: name === 'web_search' && status !== 'error' ? searchResults(result) : [],
  }
  if (count) view.countLabel = countText(count)
  if (durationLabel !== undefined) view.durationLabel = durationLabel
  if (query !== '') view.searchQuery = query
  if (splitStreams && stdout !== '') view.stdout = stdout
  if (splitStreams && stderr !== '') view.stderr = stderr
  if (name === 'terminal') {
    view.terminalCommand = shellCommand(argsRecord)
    if (exit !== undefined && Number.isInteger(exit)) view.terminalExitCode = exit
  }
  return view
}

// MARK: What the row shows

/** Painted text stops here; Copy still takes all of it. */
export const maxDisplayCharacters = 20_000

export const ToolCallViews = {
  /** An edit with a diff opens by default; everything else starts closed. */
  opensByDefault: (view: ToolCallView): boolean => view.inlineDiff !== '',

  /** A settled edit with no diff to review draws nothing, as Desktop hides it; failures and running edits still show. */
  isHidden: (view: ToolCallView): boolean => view.isFileEdit && !view.isPending && view.status !== 'error' && view.inlineDiff === '',

  /** For an error: its first paragraph, shown as a heading over the rest. */
  errorSummary: (view: ToolCallView): string => (view.status === 'error' ? errorParagraphs(view)[0] ?? '' : ''),

  /** The detail as shown: for an error, everything after `errorSummary`. */
  detailBody: (view: ToolCallView): string =>
    view.status === 'error' ? errorParagraphs(view).slice(1).join('\n\n') : view.detail,

  showsDetail(view: ToolCallView): boolean {
    if (view.inlineDiff !== '') return false
    if (view.stdout !== undefined || view.stderr !== undefined) return true
    if (view.status === 'error') return ToolCallViews.errorSummary(view) !== '' || ToolCallViews.detailBody(view) !== ''
    if (view.status === 'notice' && view.detail !== '') return true
    return view.detail !== '' && !looksRedundant(view.title, view.detail) && !looksRedundant(view.subtitle, view.detail)
  },

  /** Output, file lines and code read as code; other details as text. */
  rendersDetailAsCode: (view: ToolCallView): boolean =>
    view.status !== 'error' && (view.toolName === 'terminal' || view.toolName === 'execute_code' || view.toolName === 'read_file'),

  isExpandable: (view: ToolCallView): boolean =>
    view.inlineDiff !== '' || ToolCallViews.showsDetail(view) || view.searchHits.length > 0 || view.stdout !== undefined
    || view.stderr !== undefined || (view.terminalCommand !== undefined && view.terminalCommand !== '') || view.terminalExitCode !== undefined,

  clampForDisplay(value: string, max = maxDisplayCharacters): string {
    const count = length(value)
    if (count <= max) return value
    return `${prefix(value, max)}\n\n… ${count - max} more characters truncated`
  },

  /** Terminal output without its colour codes: the app draws it in one colour. */
  stripANSI(text: string): string {
    // eslint-disable-next-line no-control-regex
    return text.includes('\u001B') ? text.replace(/\u001B\[[0-9;?]*[ -/]*[@-~]/g, '') : text
  },

  /** Added and removed lines of a diff. */
  diffStats(diff: string): { added: number; removed: number } {
    let added = 0
    let removed = 0
    for (const line of diff.split('\n')) {
      if (line.startsWith('+') && !line.startsWith('+++')) added += 1
      if (line.startsWith('-') && !line.startsWith('---')) removed += 1
    }
    return { added, removed }
  },
} as const

function errorParagraphs(view: ToolCallView): string[] {
  return view.detail.replace(/\n\s*\n+/g, '\u001E').split('\u001E').map(trimmed).filter((part) => part !== '')
}

/** The call's diff, from its result or `tool.complete` (HermesKit's `TranscriptItem.toolDiff`). */
export function toolDiff(item: TranscriptItem): string | undefined {
  if (!item.tool) return undefined
  return nonEmpty(inlineDiff({ ...toolMetadata(item.tool), ...record(toolResult(item.tool)) }))
}

// MARK: Inputs

/** The call's result: the structured one when known, else the output text read as JSON when it is JSON. */
export function toolResult(tool: ToolActivity): JSONValue | undefined {
  if (tool.result !== undefined) return tool.result
  if (tool.output === undefined) return undefined
  if (trimmed(tool.output) === '') return ''
  return parseJSON(tool.output) ?? tool.output
}

function toolMetadata(tool: ToolActivity | undefined): JSONRecord {
  const metadata: JSONRecord = {}
  if (!tool) return metadata
  if (tool.durationSeconds !== undefined) metadata.duration_s = tool.durationSeconds
  if (tool.summary !== undefined) metadata.summary = tool.summary
  if (tool.inlineDiff !== undefined) metadata.inline_diff = tool.inlineDiff
  if (tool.error !== undefined) metadata.error = tool.error
  return metadata
}

/** An object, or a string holding one; anything else is empty (`parseMaybeObject`). */
function record(value: JSONValue | undefined): JSONRecord {
  if (isRecord(value)) return value
  if (typeof value === 'string' && trimmed(value) !== '') {
    const parsed = parseJSON(value)
    if (isRecord(parsed)) return parsed
  }
  return {}
}

/** `Number(value)`, as Desktop's `numberValue` reads it. */
function numberOf(value: JSONValue | undefined): number | undefined {
  if (typeof value === 'number') return value
  if (typeof value === 'string') {
    const text = trimmed(value)
    if (text === '') return 0
    const parsed = Number(text)
    return Number.isNaN(parsed) ? undefined : parsed
  }
  if (typeof value === 'boolean') return value ? 1 : 0
  if (value === null) return 0
  return undefined
}

/** The `context`/`preview` of an object, or the string itself (`contextValue`). */
function contextValue(value: JSONValue | undefined): string {
  const row = record(value)
  const context = stringValue(row.context)
  if (context !== undefined) return context
  const previewText = stringValue(row.preview)
  if (previewText !== undefined) return previewText
  return stringValue(value) ?? ''
}

function compactPreview(value: string, max = 72): string {
  const line = trimmed(value.replace(/\s+/g, ' '))
  return length(line) > max ? prefix(line, max - 1) + '…' : line
}

/** `compactPreview` of an object: its `context`, as text. */
function compactRecord(row: JSONRecord, max: number): string {
  const context = row.context
  if (context === undefined || context === null) return ''
  if (typeof context === 'string') return compactPreview(context, max)
  return compactPreview(sortedJSON(context), max)
}

const urlPattern = /https?:\/\/[^\s'"<>)\]]+/i

/** The first URL anywhere in the values, depth first. */
function firstURL(...sources: (JSONValue | undefined)[]): string {
  for (const source of sources) {
    if (source === undefined) continue
    const url = firstURLIn(source)
    if (url !== undefined) return url
  }
  return ''
}

function firstURLIn(value: JSONValue): string | undefined {
  if (typeof value === 'string') return urlPattern.exec(value)?.[0]
  if (Array.isArray(value)) {
    for (const item of value) {
      const url = firstURLIn(item)
      if (url !== undefined) return url
    }
    return undefined
  }
  if (isRecord(value)) {
    for (const key of Object.keys(value).sort()) {
      const url = firstURLIn(value[key]!)
      if (url !== undefined) return url
    }
  }
  return undefined
}

// MARK: Status

function statusOf(part: Part, result: JSONRecord): ToolCallStatus {
  if (part.result === undefined && part.isPending) return 'running'
  if (part.result === undefined && !part.isError) return 'warning'
  if (result.success === true || result.ok === true) return 'success'
  const error = errorText(part, result)
  if (error === '') return 'success'
  // A guessed read path missing is routine exploration, not a broken tool.
  if (part.name === 'read_file' && /^File not found:/i.test(error)) return 'notice'
  if (part.name === 'terminal' && error === 'Command failed with exit code 1.') return 'notice'
  // A refused memory write is a budget negotiation, not a failure.
  return part.name === 'memory' ? 'warning' : 'error'
}

function errorText(part: Part, result: JSONRecord): string {
  const extracted = ToolResultText.errorMessage(part.result)
  if (part.isError) {
    if (extracted !== '') return extracted
    const envelope = trimmed(stringValue(part.metadata.error) ?? stringValue(part.metadata.message) ?? '')
    if (envelope !== '') return envelope
    const text = trimmed(stringValue(part.result) ?? '')
    if (text !== '') return text
    return 'Tool returned an error.'
  }
  if (extracted !== '') return extracted
  if (result.success === false || result.ok === false) {
    return nonEmpty(firstString(result, ['message', 'reason', 'detail'])) ?? 'Tool returned success=false.'
  }
  const status = stringValue(result.status)
  if (status !== undefined && ToolResultText.isFailureStatus(status)) {
    return nonEmpty(firstString(result, ['message', 'reason', 'detail'])) ?? `Tool returned status "${status}".`
  }
  // A non-zero exit code alone is a weak failure signal (grep's no-match, diff's
  // differences): only an error when the command printed nothing.
  const exit = numberOf(result.exit_code)
  if (exit !== undefined && exit !== 0) {
    const hasOutput = firstString(result, ['output', 'stdout', 'stderr', 'output_preview']) !== ''
    return hasOutput ? '' : `Command failed with exit code ${numberText(exit)}.`
  }
  return ''
}

/** The call reported failure, from its flag or its result (`toolCallFailed`). */
function failed(part: Part): boolean {
  const result = record(part.result)
  return result.success !== true && result.ok !== true
    && (part.isError || result.success === false || result.ok === false || ToolResultText.errorMessage(part.result) !== '')
}

// MARK: Titles

interface Meta { done: string; pending: string }

const titles: Record<string, Meta> = {
  browser_click: { done: 'Clicked page element', pending: 'Clicking page element' },
  browser_fill: { done: 'Filled form field', pending: 'Filling form field' },
  browser_navigate: { done: 'Opened page', pending: 'Opening page' },
  browser_snapshot: { done: 'Captured page snapshot', pending: 'Capturing page snapshot' },
  browser_take_screenshot: { done: 'Captured screenshot', pending: 'Capturing screenshot' },
  browser_type: { done: 'Typed on page', pending: 'Typing on page' },
  clarify: { done: 'Asked a question', pending: 'Asking a question' },
  cronjob: { done: 'Cron job', pending: 'Scheduling cron job' },
  edit_file: { done: 'Edited file', pending: 'Editing file' },
  execute_code: { done: 'Ran code', pending: 'Scripting' },
  image_generate: { done: 'Generated image', pending: 'Generating image' },
  list_files: { done: 'Listed files', pending: 'Listing files' },
  memory: { done: 'Saved to memory', pending: 'Saving to memory' },
  patch: { done: 'Patched file', pending: 'Patching file' },
  read_file: { done: 'Read file', pending: 'Reading file' },
  search_files: { done: 'Searched files', pending: 'Searching files' },
  session_search_recall: { done: 'Searched session history', pending: 'Searching session history' },
  terminal: { done: 'Ran command', pending: 'Running command' },
  todo: { done: 'Updated todos', pending: 'Updating todos' },
  vision_analyze: { done: 'Analyzed image', pending: 'Analyzing image' },
  web_extract: { done: 'Read webpage', pending: 'Reading webpage' },
  web_search: { done: 'Searched web', pending: 'Searching web' },
  write_file: { done: 'Edited file', pending: 'Editing file' },
}

/** A known tool's words; any other is named after itself ("Browser Scroll"). */
function metaOf(name: string): Meta {
  const known = titles[name]
  if (known) return known
  let short = name
  for (const start of ['browser_', 'web_']) if (short.startsWith(start)) short = short.slice(start.length)
  const parts = short.split('_').filter((part) => part !== '').map(capitalize)
  const action = parts.length === 0 ? name : parts.join(' ')
  for (const [start, label] of [['browser_', 'Browser'], ['web_', 'Web']] as const) {
    if (name.startsWith(start)) return { done: `${label} ${action}`, pending: `Running ${label.toLowerCase()} ${action.toLowerCase()}` }
  }
  return { done: action, pending: `Running ${action.toLowerCase()}` }
}

/** The title that names what the call acted on, or undefined for the tool's own words. */
function dynamicTitle(part: Part, args: JSONRecord, result: JSONRecord): string | undefined {
  const skill = skillTitle(part)
  if (skill !== undefined) return skill
  const pending = part.result === undefined
  const verb = (gerund: string, past: string) => (pending ? gerund : past)
  switch (part.name) {
    case 'web_extract': {
      const url = firstURL(args, result)
      return url === '' ? undefined : `${verb('Reading', 'Read')} ${hostname(url)}`
    }
    case 'browser_navigate': {
      const url = firstURL(args, result)
      if (url === '') return undefined
      const didFail = part.isError || result.success === false || result.ok === false || firstString(result, ['error']) !== ''
      return `${didFail ? 'Failed to open' : verb('Opening', 'Opened')} ${hostname(url)}`
    }
    case 'web_search': {
      const query = nonEmpty(firstString(args, ['search_term', 'query'])) ?? contextValue(args)
      return query === '' ? undefined : `${verb('Searching', 'Searched')} “${compactPreview(query, 48)}”`
    }
    case 'read_file': {
      const target = readFileTarget(args, result)
      return target === '' ? undefined : `${verb('Reading', 'Read')} ${target}`
    }
    case 'terminal': case 'execute_code': {
      const command = shellCommand(args)
      if (command === '') return undefined
      const action = part.name === 'execute_code' ? verb('Scripting', 'Ran code') : verb('Running', 'Ran')
      const summary = compactPreview(ToolCallSummary.summarizeShellCommand(command), 160)
      return `${action} ${withoutLeadingAction(summary, action)}`
    }
    case 'browser_exec':
      return browserExecStepLabel(firstString(args, ['code']))
    default: {
      if (!fileEditTools.has(part.name)) return undefined
      const path = fileEditPath(args, result)
      return path === '' ? undefined : basename(path)
    }
  }
}

/** Loading a skill, reading one of its files or listing them (`skill-activity.ts`). */
function skillTitle(part: Part): string | undefined {
  if (part.name !== 'skill_view' && part.name !== 'skills_list') return undefined
  const args = record(part.args)
  const didFail = failed(part)
  const pending = part.isPending && part.result === undefined
  const missing = !pending && part.result === undefined
  const file = firstString(args, ['file_path'])
  const target = [firstString(args, ['name']), file].filter((value) => value !== '').join(' → ')
  const words = part.name === 'skills_list'
    ? { pending: 'Listing skills', done: 'Listed skills', failed: 'Failed to list skills' }
    : file !== ''
      ? { pending: 'Reading skill resource', done: 'Read skill resource', failed: 'Failed to read skill resource' }
      : { pending: 'Loading skill', done: 'Loaded skill', failed: 'Failed to load skill' }
  const label = didFail ? words.failed : missing ? 'Skill result unavailable' : pending ? words.pending : words.done
  return target === '' ? label : `${label}: ${target}`
}

/** "notes.md L237-259": the file, and the lines read when the call chose them. */
function readFileTarget(args: JSONRecord, result: JSONRecord): string {
  const inherited = firstString(args, ['context', 'preview'])
  if (inherited !== '') return inherited
  const path = firstString(args, ['path', 'file', 'filepath'])
  if (path === '') return ''
  return [basename(path), readFileLines(args, result)].filter((value) => value !== '').join(' ')
}

function readFileLines(args: JSONRecord, result: JSONRecord): string {
  const offset = numberValue(args.offset)
  const limit = numberValue(args.limit)
  if (offset === undefined && limit === undefined) return ''
  if (offset !== undefined && offset > 0) {
    if (limit === undefined || limit <= 1) return `L${numberText(offset)}`
    return `L${numberText(offset)}-${numberText(offset + limit - 1)}`
  }
  const lines = firstString(result, ['content']).split('\n').filter((line) => line !== '').flatMap((line) => {
    const bar = line.indexOf('|')
    if (bar <= 0) return []
    const digits = line.slice(0, bar)
    return /^[0-9]+$/.test(digits) ? [Number(digits)] : []
  })
  const start = lines[0]
  const end = lines[lines.length - 1]
  if (start === undefined || end === undefined) return ''
  return start === end ? `L${start}` : `L${start}-${end}`
}

/** The command that ran, preferring the argument over the gateway's preview. */
function shellCommand(args: JSONRecord): string {
  return nonEmpty(firstString(args, ['command', 'code'])) ?? nonEmpty(firstString(args, ['context', 'preview'])) ?? contextValue(args)
}

/** A preview that already opens with the title's verb loses it ("Running grep"). */
function withoutLeadingAction(value: string, action: string): string {
  const verb = trimmed(action)
  const text = value.replace(/^\s+/, '')
  const boundary = text.search(/\s/)
  if (verb === '' || boundary < 0) return value
  return text.slice(0, boundary).toLowerCase() === verb.toLowerCase() ? text.slice(boundary).replace(/^\s+/, '') : value
}

/** `browser_exec` code opens with a `# …` line saying what the step does. */
function browserExecStepLabel(code: string, maxCharacters = 80): string | undefined {
  const first = trimmed(trimmed(code).split('\n')[0] ?? '')
  if (!first.startsWith('#')) return undefined
  const label = trimmed(first.replace(/^#+/, ''))
  if (label === '') return undefined
  return length(label) > maxCharacters ? prefix(label, maxCharacters - 1) + '…' : label
}

function fileEditPath(args: JSONRecord, result: JSONRecord): string {
  return nonEmpty(firstString(args, ['path', 'file', 'filepath']))
    ?? nonEmpty(firstString(result, ['path', 'file', 'filepath', 'resolved_path']))
    ?? htmlPath(firstString(result, ['inline_diff', 'diff']))
}

function htmlPath(diff: string): string {
  const match = /(?:^|\s)(?:[ab]\/)?([^\s]+\.html?)(?=\s|$)/i.exec(stripDiffChrome(diff))
  return match ? trimmed(match[1]!) : ''
}

// MARK: Subtitle and detail

function subtitleOf(part: Part, args: JSONRecord, result: JSONRecord): string {
  switch (part.name) {
    case 'browser_navigate': {
      const url = nonEmpty(firstString(args, ['url', 'target'])) ?? nonEmpty(firstString(result, ['url'])) ?? firstURL(args, result)
      return url === '' ? 'Navigated in browser' : hostname(url)
    }
    case 'browser_snapshot': {
      const snapshot = firstString(result, ['snapshot'])
      return snapshot === '' ? 'Captured a browser accessibility snapshot' : summarizeSnapshot(snapshot)
    }
    case 'browser_click': {
      const clicked = nonEmpty(firstString(result, ['clicked'])) ?? firstString(args, ['ref', 'target'])
      if (clicked === '') return 'Clicked on page'
      return clicked.startsWith('@') ? `Clicked page element (internal ref ${clicked})` : `Clicked ${clicked}`
    }
    case 'browser_fill': case 'browser_type': {
      const field = firstString(args, ['label', 'field', 'ref', 'target'])
      const value = firstString(args, ['value', 'text'])
      const parts = [field === '' ? '' : `Field: ${field}`, value === '' ? '' : `Value: ${compactPreview(value, 42)}`]
      return nonEmpty(parts.filter((text) => text !== '').join(' · ')) ?? 'Filled page input'
    }
    case 'web_search': {
      const query = nonEmpty(firstString(args, ['search_term', 'query'])) ?? contextValue(args)
      return query === '' ? 'Queried web sources' : `Query: ${query}`
    }
    case 'terminal': case 'execute_code': {
      const source = trimmed(nonEmpty(firstString(result, ['output', 'stdout', 'stderr'])) ?? lines(result))
      const line = source.split('\n').map(trimmed).find((text) => text !== '')
      if (line !== undefined) return compactPreview(line, 160)
      const command = nonEmpty(firstString(args, ['context', 'preview', 'command', 'code'])) ?? contextValue(args)
      return command === '' ? 'Executed command' : ''
    }
    case 'read_file': {
      const path = firstString(args, ['path', 'file', 'filepath'])
      return path === '' ? fallbackDetail(args, result) : path
    }
    case 'web_extract': {
      const url = nonEmpty(firstString(args, ['url'])) ?? nonEmpty(firstString(result, ['url'])) ?? firstURL(args, result)
      return url === '' ? 'Fetched webpage' : hostname(url)
    }
    case 'memory':
      return firstString(result, ['message', 'error'])
    case 'cronjob':
      return cronSubtitle(args, result)
    default: {
      if (fileEditTools.has(part.name)) {
        const path = fileEditPath(args, result)
        return path === '' ? (inlineDiff(result) === '' ? '' : 'Changed file') : path
      }
      return nonEmpty(compactPreview(ToolResultText.summary(part.result), 120))
        ?? nonEmpty(compactRecord(result, 120))
        ?? nonEmpty(compactRecord(args, 120))
        ?? fallbackDetail(args, result)
    }
  }
}

function detailText(part: Part, args: JSONRecord, result: JSONRecord): string {
  switch (part.name) {
    case 'browser_snapshot': {
      const snapshot = firstString(result, ['snapshot'])
      return snapshot === '' ? fallbackDetail(args, result) : summarizeSnapshot(snapshot)
    }
    case 'terminal': case 'execute_code': {
      // Split streams are their own sections; this is the merged fallback.
      const output = firstString(result, ['output', 'stdout', 'stderr'])
      const text = lines(result)
      if (output !== '' || text !== '') return [output, text].filter((value) => value !== '').join('\n')
      // A terminal row shows its command as `$ command` already.
      if (part.name === 'terminal') return ''
      break
    }
    case 'web_extract': {
      const direct = firstString(result, ['content', 'text', 'markdown', 'body', 'summary', 'message'])
      if (direct !== '') return trimmed(direct.replace(/\s*in\s+\d+(?:\.\d+)?s\s*$/i, ''))
      const aggregated = (arrayValue(result.results) ?? []).map((item) => firstString(record(item), ['content', 'text', 'markdown', 'body']))
        .filter((text) => text !== '').join('\n\n---\n\n')
      if (aggregated !== '') return aggregated
      break
    }
    case 'read_file': {
      if (part.result !== undefined) {
        const content = firstString(result, ['content', 'text', 'data', 'body'])
        if (content !== '') return content
      }
      break
    }
    case 'memory':
      return firstString(result, ['message', 'error'])
    case 'web_search': {
      const detail = fallbackDetail(args, result)
      const seconds = numberOf(result.duration_s)
      if (seconds === undefined) return detail
      const shown = duration(seconds)
      if (shown === '') return detail
      return detail
        .replace(/^\s*-\s*Duration\s+S\s*:\s*[-+]?[\d.]+(?:e[-+]?\d+)?\s*$/gim, `- Duration: ${shown}`)
        .replace(/\bDuration\s+S\s*:/gi, 'Duration:')
    }
    case 'cronjob':
      return cronDetail(args, result)
    default: {
      if (fileEditTools.has(part.name)) {
        if (inlineDiff(record(part.result)) !== '') return ''
        const summary = firstString(result, ['message', 'summary'])
        if (summary !== '') return summary
        if (fileEditPath(args, result) !== '') return ''
      }
    }
  }
  return fallbackDetail(args, result)
}

/** The call's own words for itself, else a summary of its result. */
function fallbackDetail(args: JSONRecord, result: JSONRecord): string {
  const argContext = contextValue(args)
  const resultContext = contextValue(result)
  if (resultContext !== '' && resultContext !== argContext) return resultContext
  if (argContext !== '') return argContext
  return ToolResultText.summary(result)
}

function lines(result: JSONRecord): string {
  return (arrayValue(result.lines) ?? []).flatMap((line) => (typeof line === 'string' ? [line] : [])).join('\n')
}

function stripDividerLines(value: string): string {
  return trimmed(value.split('\n').filter((line) => !/^[-=]{3,}\s*$/.test(trimSpaces(line))).join('\n'))
}

function looksRedundant(title: string, detail: string): boolean {
  if (detail === '') return true
  const norm = (text: string) => trimmed(text.toLowerCase().replace(/\s+/g, ' '))
  return norm(title) === norm(detail)
}

function summarizeSnapshot(snapshot: string): string {
  const count = (pattern: RegExp) => snapshot.match(pattern)?.length ?? 0
  const stats = [`${count(/button\s+"[^"]+"/g)} buttons`, `${count(/link\s+"[^"]+"/g)} links`,
    `${count(/(?:textbox|combobox|searchbox)\s+"[^"]+"/g)} inputs`].join(' · ')
  const labels: string[] = []
  for (const match of snapshot.matchAll(/(?:button|link|combobox|textbox)\s+"([^"]+)"/g)) {
    const label = trimmed(match[1]!)
    if (label !== '') labels.push(label)
    if (labels.length === 4) break
  }
  return labels.length === 0 ? stats : `${stats}\nTop controls: ${labels.join(', ')}`
}

function cronSubtitle(args: JSONRecord, result: JSONRecord): string {
  const jobs = arrayValue(result.jobs)
  if (jobs) return jobs.length === 0 ? 'No cron jobs' : `${jobs.length} cron job${jobs.length === 1 ? '' : 's'}`
  const message = firstString(result, ['message'])
  if (message !== '') return message
  const action = nonEmpty(firstString(args, ['action'])) ?? 'manage'
  const name = nonEmpty(firstString(result, ['name'])) ?? firstString(args, ['name', 'job_id'])
  return name === '' ? `Cron ${action}` : `${capitalize(action)} ${name}`
}

function cronDetail(args: JSONRecord, result: JSONRecord): string {
  const jobs = arrayValue(result.jobs)
  if (jobs) {
    if (jobs.length === 0) return 'No cron jobs scheduled'
    return jobs.slice(0, 20).map((job) => {
      const row = record(job)
      const name = nonEmpty(firstString(row, ['name', 'id'])) ?? 'job'
      const schedule = firstString(row, ['schedule_display', 'schedule'])
      return schedule === '' ? `- ${name}` : `- ${name} · ${schedule}`
    }).join('\n')
  }
  const scalar = (value: JSONValue | undefined) =>
    typeof value === 'string' ? trimmed(value) : typeof value === 'number' ? numberText(value) : ''
  const nextRun = scalar(result.next_run_at)
  const rows: [string, string][] = [['Schedule', scalar(result.schedule)], ['Repeat', scalar(result.repeat)],
    ['Delivery', scalar(result.deliver)], ['Next run', nextRun === '' ? '' : cronTime(nextRun)]]
  const shown = rows.filter(([, value]) => value !== '').map(([label, value]) => `${label}: ${value}`)
  return shown.length === 0 ? fallbackDetail(args, result) : shown.join('\n')
}

function cronTime(iso: string): string {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime()) || !/^\d{4}-\d{2}-\d{2}T/.test(iso)) return iso
  return date.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}

// MARK: Diffs, counts, search

function stripDiffChrome(value: string): string {
  // eslint-disable-next-line no-control-regex
  return trimmed(value.replace(/\u001B\[[0-9;]*[A-Za-z]/g, '').replace(/^\s*┊\s*review diff\s*\n/i, ''))
}

function inlineDiff(result: JSONRecord): string {
  for (const key of ['inline_diff', 'diff']) {
    const value = stringValue(result[key])
    if (value !== undefined && trimmed(value) !== '') return stripDiffChrome(value)
  }
  return ''
}

/** "850ms", "4.2s", "45s", "1m 5s", "2h 3m" (`formatDuration`). */
export function duration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return ''
  if (seconds < 1) return `${Math.max(1, Math.round(seconds * 1000))}ms`
  if (seconds < 60) return seconds >= 10 ? `${seconds.toFixed(0)}s` : `${seconds.toFixed(1)}s`
  const whole = Math.round(seconds)
  const minutes = Math.floor(whole / 60)
  const rest = whole % 60
  if (minutes < 60) return rest > 0 ? `${minutes}m ${rest}s` : `${minutes}m`
  const hours = Math.floor(minutes / 60)
  const restMinutes = minutes % 60
  return restMinutes > 0 ? `${hours}h ${restMinutes}m` : `${hours}h`
}

interface Count { count: number; noun: string }

const countFields: [string, string][] = [
  ['count', ''], ['total', ''], ['result_count', 'result'], ['results_count', 'result'],
  ['num_results', 'result'], ['match_count', 'match'], ['matches_count', 'match'], ['file_count', 'file'],
  ['files_count', 'file'], ['item_count', 'item'], ['items_count', 'item'], ['search_count', 'search'],
  ['searches_count', 'search'], ['source_count', 'source'], ['sources_count', 'source'],
  ['document_count', 'document'], ['documents_count', 'document'], ['updated', 'item'], ['added', 'item'],
  ['removed', 'item'], ['deleted', 'item'], ['created', 'item'], ['changed', 'item'], ['processed', 'item'],
  ['steps', 'step'],
]
const countArrays: [string, string][] = [
  ['results', 'result'], ['items', 'item'], ['matches', 'match'], ['files', 'file'],
  ['documents', 'document'], ['sources', 'source'], ['rows', 'row'],
]
const defaultCountNouns: Record<string, string> = {
  browser_snapshot: 'item', list_files: 'file', search_files: 'result', session_search_recall: 'result',
  todo: 'todo', todo_list: 'todo', web_search: 'result',
}

function countValue(value: JSONValue | undefined): number | undefined {
  if (Array.isArray(value)) return value.length === 0 ? undefined : value.length
  const amount = numberOf(value)
  if (amount === undefined || !(amount > 0) || amount >= 1e15) return undefined
  return Math.round(amount)
}

function singular(noun: string): string {
  const word = trimmed(noun).toLowerCase()
  if (word === '') return ''
  if (word.endsWith('ies') && word.length > 3) return word.slice(0, -3) + 'y'
  if (/(xes|zes|ches|shes|sses)$/.test(word) && word.length > 3) return word.slice(0, -2)
  if (word.endsWith('s') && word.length > 2 && !word.endsWith('ss')) return word.slice(0, -1)
  return word
}

function plural(noun: string, count: number): string {
  if (count === 1) return noun
  if (noun === 'search') return 'searches'
  if (noun.endsWith('y') && noun.length > 1 && !/[aeiou]y$/i.test(noun)) return noun.slice(0, -1) + 'ies'
  if (/(s|x|z|ch|sh)$/i.test(noun)) return noun + 'es'
  return noun + 's'
}

const makeCount = (count: number, noun: string): Count => ({ count, noun: nonEmpty(singular(noun)) ?? 'item' })

const countText = (metric: Count) => `${metric.count} ${plural(metric.noun, metric.count)}`

function countFromRecord(row: JSONRecord, fallback: string): Count | undefined {
  for (const [key, noun] of countFields) {
    const value = countValue(row[key])
    if (value !== undefined) return makeCount(value, nonEmpty(noun) ?? fallback)
  }
  for (const [key, noun] of countArrays) {
    const value = countValue(row[key])
    if (value !== undefined) return makeCount(value, noun)
  }
  for (const key of Object.keys(row).sort()) {
    if (['duration_s', 'exit_code', 'status_code'].includes(key)) continue
    if (!/_count$|_total$/i.test(key)) continue
    const value = countValue(row[key])
    if (value === undefined) continue
    const stripped = key.toLowerCase().replace(/_(count|total)$/, '').replace(/^num_/, '')
    return makeCount(value, nonEmpty(singular(stripped)) ?? fallback)
  }
  return undefined
}

function countFromText(value: string, fallback: string): Count | undefined {
  const text = trimmed(value)
  if (text === '') return undefined
  const unit = /\b(\d+)\s+(results?|items?|files?|matches?|documents?|sources?|searches?|steps?|rows?)\b/i
  const verb = /\b(?:did|found|returned|listed|searched|matched|updated|created|deleted|processed)\s+(\d+)\b/i
  for (const [pattern, hasNoun] of [[unit, true], [verb, false]] as const) {
    const match = pattern.exec(text)
    if (!match) continue
    const number = Number(match[1])
    if (!(number > 0)) return undefined
    return makeCount(number, hasNoun ? singular(match[2]!) : fallback)
  }
  return undefined
}

function resultCount(part: Part, args: JSONRecord, result: JSONRecord): Count | undefined {
  if (part.result === undefined) return undefined
  const fallback = defaultCountNouns[part.name] ?? 'item'
  const normalized = (metric: Count) => (part.name === 'web_search' ? makeCount(metric.count, 'result') : metric)
  if (part.name === 'web_search') {
    const hits = resultItems(part.result)
    if (hits.length > 0) return makeCount(hits.length, 'result')
  }
  // Memory's live total is its `entry_count`.
  if (part.name === 'memory') {
    const total = countValue(result.entry_count)
    if (total !== undefined) return makeCount(total, 'entry')
  }
  const direct = countFromRecord(result, fallback)
  if (direct) return normalized(direct)
  const payload = unwrapPayload(part.result)
  if (isRecord(payload)) {
    const nested = countFromRecord(payload, fallback)
    if (nested) return normalized(nested)
  }
  const summary = nonEmpty(firstString(result, ['summary', 'message', 'detail'])) ?? fallbackDetail(args, result)
  const fromText = countFromText(summary, fallback)
  return fromText ? normalized(fromText) : undefined
}

function resultItems(value: JSONValue): JSONValue[] {
  if (Array.isArray(value)) return value
  const row = record(value)
  for (const key of ['web', 'results', 'search_results', 'sources', 'web_sources', 'items', 'organic_results',
    'organic', 'matches', 'documents']) {
    const child = row[key]
    if (Array.isArray(child)) return child
    if (isRecord(child)) {
      const items = resultItems(child)
      if (items.length > 0) return items
    }
  }
  const payload = unwrapPayload(row)
  return jsonEqual(payload, row) ? [] : resultItems(payload)
}

function searchResults(result: JSONValue | undefined, limit = 6): SearchHit[] {
  if (result === undefined) return []
  return resultItems(result).map((item) => {
    const row = record(item)
    return {
      title: cleanVisibleText(firstString(row, ['title', 'name'])),
      url: firstString(row, ['url', 'href', 'link']),
      snippet: cleanVisibleText(firstString(row, ['snippet', 'description', 'body'])),
    }
  }).filter((hit) => hit.title !== '' || hit.url !== '').slice(0, limit)
}

/** Model text without fence noise, citation markers or Markdown link syntax; inline code spans stay. */
function cleanVisibleText(text: string): string {
  let out = ''
  let rest = text
  for (;;) {
    const match = /`[^`\n]+`/.exec(rest)
    if (!match) break
    out += cleanPlain(rest.slice(0, match.index)) + match[0]
    rest = rest.slice(match.index + match[0].length)
  }
  return out + cleanPlain(rest)
}

function cleanPlain(text: string): string {
  return text.replace(/`{3,}/g, '')
    .replace(/(?<=[\p{L}\p{N})\].,!?:;"'”’])\[(?:\d+(?:\s*,\s*\d+)*)\](?!\()/gu, '')
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '$1 $2')
}
