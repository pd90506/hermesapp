import type { JSONValue } from '../protocol/jsonrpc.ts'
import { originalFileNames } from '../media/file-names.ts'

/** An image in a user message (HermesKit's `TranscriptImage`). */
export interface TranscriptImage {
  /** Shown under a placeholder when the image cannot be loaded. */
  name: string
  /** Where it lives on the gateway: a stored `@image:` path, or an upload's path. */
  path?: string
  /** The composer attachment it was sent from (its thumbnail is on this device). */
  localID?: string
  position: number
}

export function imageID(image: TranscriptImage): string {
  return `${image.position}:${image.path ?? image.localID ?? image.name}`
}

/** The images of a stored message's `@image:` paths, in order. */
export function storedImages(paths: readonly string[]): TranscriptImage[] {
  return paths.map((path, position) => ({ name: lastPathComponent(path), path, position }))
}

export function lastPathComponent(path: string): string {
  // A Windows gateway's paths use backslashes (E: `C:\Users\…\images\a.png`).
  const trimmed = path.replace(/[\\/]+$/, '')
  const index = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'))
  return index >= 0 ? trimmed.slice(index + 1) : trimmed
}

export type ToolPhase = 'running' | 'complete' | 'failed'

/** One tool call (`tool.start` → `tool.complete`; HermesKit's `ToolActivity`). */
export interface ToolActivity {
  toolID: string
  name: string
  phase: ToolPhase
  context?: string
  args?: JSONValue
  summary?: string
  output?: string
  result?: JSONValue
  inlineDiff?: string
  durationSeconds?: number
  error?: string
}

/** A `/btw` question or `/bg` task and its answer (HermesKit's `SideQuestion`). */
export interface SideQuestion {
  taskID: string
  question?: string
  /** Undefined while pending. */
  answer?: string
  kind: 'btw' | 'background'
}

export type TranscriptRole = 'user' | 'assistant' | 'tool' | 'system'

/**
 * One row of the chat as the UI shows it (HermesKit's `TranscriptItem`). Rows are
 * immutable: the transcript replaces a row to change it, so a view can tell a changed
 * row by identity.
 */
export interface TranscriptItem {
  readonly id: string
  readonly role: TranscriptRole
  readonly text: string
  /** Assistant reasoning streamed alongside the reply. */
  readonly reasoning: string
  /** Local submission state ("Sending…", "Queued", "Not confirmed · …"). */
  readonly outgoingStatus?: string
  readonly toolName?: string
  readonly detail?: string
  /** Assistant: still receiving deltas. Tool: still running. */
  readonly isActive: boolean
  /** Assistant: `message.complete` status. */
  readonly outcome?: string
  /** The stored row (`messages.id`) this item shows. */
  readonly rowID?: number
  /** Unix milliseconds: a stored row's timestamp, or when a prompt was sent here. */
  readonly timestamp?: number
  readonly toolCallID?: string
  readonly images: readonly TranscriptImage[]
  readonly attachments: readonly string[]
  readonly attachmentPaths: readonly string[]
  readonly displayKind?: string
  /** Assistant commentary beside tool calls (`message.interim`). */
  readonly isInterim: boolean
  readonly tool?: ToolActivity
  readonly sideQuestion?: SideQuestion
}

export const queuedStatus = 'Queued'
export const compressionDisplayKind = 'compression'
export const reviewDisplayKind = 'review'

export function makeItem(id: string, role: TranscriptRole, text: string, isActive = false): TranscriptItem {
  return { id, role, text, reasoning: '', isActive, images: [], attachments: [], attachmentPaths: [], isInterim: false }
}

/** A user row that steered a running turn rather than starting one. */
export const isSteer = (item: TranscriptItem): boolean => item.displayKind === 'steer'
/** A prompt waiting in Hermes's queue. */
export const isQueuedPrompt = (item: TranscriptItem): boolean => item.role === 'user' && item.outgoingStatus === queuedStatus
export const isCompressionNote = (item: TranscriptItem): boolean =>
  item.role === 'system' && item.displayKind === compressionDisplayKind

/** Reply text that is not blank. */
export const hasReplyText = (item: TranscriptItem): boolean => item.text.trim() !== ''

/** An assistant row with nothing to show (no text, reasoning or interrupt mark). */
export const isBlankReply = (item: TranscriptItem): boolean =>
  item.role === 'assistant' && !hasReplyText(item) && item.reasoning === '' && item.outcome !== 'interrupted'

// MARK: - `@image:` lines, image hints, `@file:` references

const imagePrefix = '@image:'

/** The value of a line that is exactly one `<prefix><value>` reference (`ImageDirectives.value`). */
export function referenceValue(line: string, prefix: string): string | undefined {
  const trimmed = line.replace(/^[ \t]+|[ \t]+$/g, '')
  if (!trimmed.startsWith(prefix)) return undefined
  const value = trimmed.slice(prefix.length)
  const first = value[0]
  if (first === undefined) return undefined
  if ('`"\''.includes(first)) {
    if (value.length < 2 || value[value.length - 1] !== first) return undefined
    const inner = value.slice(1, -1)
    return inner === '' || inner.includes(first) ? undefined : inner
  }
  return /\s/.test(value) ? undefined : value
}

/** The path of a line that is exactly one `@image:` directive. */
export function imageDirectivePath(line: string): string | undefined {
  return referenceValue(line, imagePrefix)
}

const hintAttached = '[The user attached an image: '
const hintExamine = '[Examine it with the vision_analyze tool using image_url: '
const defaultImageQuestion = 'What do you see in this image?'

/** The leading vision-tool hints of a stored row (HermesKit's `ImageHints.splitLeading`). */
export function splitLeadingImageHints(text: string): { text: string; paths: string[] } {
  if (!text.startsWith(hintAttached)) return { text, paths: [] }
  let lines = text.split('\n')
  const paths: string[] = []
  while (lines.length >= 2) {
    const [first, second] = lines as [string, string]
    if (!(first.startsWith(hintAttached) && first.endsWith(']') && second.startsWith(hintExamine) && second.endsWith(']'))) break
    const path = second.slice(hintExamine.length, -1)
    if (path === '') break
    paths.push(path)
    lines = lines.slice(2)
    while (lines[0] === '') lines = lines.slice(1)
  }
  if (paths.length === 0) return { text, paths: [] }
  const rest = lines.join('\n').trim()
  return { text: rest === defaultImageQuestion ? '' : rest, paths }
}

/** The caption and the `@image:` paths of a stored user message (HermesKit's `ImageDirectives.split`). */
export function splitImageDirectives(text: string): { caption: string; paths: string[] } {
  const hinted = splitLeadingImageHints(text)
  if (hinted.paths.length > 0) {
    const rest = splitImageDirectives(hinted.text)
    return { caption: rest.caption, paths: [...hinted.paths, ...rest.paths] }
  }
  if (!text.includes(imagePrefix)) return { caption: text, paths: [] }
  const caption: string[] = []
  const paths: string[] = []
  for (const line of text.split('\n')) {
    const path = imageDirectivePath(line)
    if (path !== undefined) paths.push(path)
    else caption.push(line)
  }
  if (paths.length === 0) return { caption: text, paths: [] }
  while (caption.length > 0) {
    const last = caption[caption.length - 1]!.replace(/^[ \t]+|[ \t]+$/g, '')
    if (last === '' || imagePlaceholders.has(last)) caption.pop()
    else break
  }
  return { caption: caption.join('\n').trim(), paths }
}

const attachmentPrefixes = ['@file:', '@folder:']

/** The leading `@file:` / `@folder:` lines lifted off (HermesKit's `AttachmentRefs.splitLeading`). */
export function splitLeadingAttachmentRefs(text: string): { text: string; refs: string[] } {
  if (!text.startsWith('@')) return { text, refs: [] }
  let lines = text.split('\n')
  const refs: string[] = []
  while (lines.length > 0) {
    const value = attachmentReference(lines[0]!)
    if (value === undefined) break
    refs.push(value)
    lines = lines.slice(1)
  }
  if (refs.length === 0) return { text, refs: [] }
  return { text: lines.join('\n').trim(), refs }
}

function attachmentReference(line: string): string | undefined {
  if (!line.startsWith('@')) return undefined
  for (const prefix of attachmentPrefixes) {
    const value = referenceValue(line, prefix)
    if (value !== undefined) return value
  }
  return undefined
}

/** What a bubble shows for a reference: its file name. */
export function attachmentDisplayName(ref: string): string {
  const original = originalFileNames.name(ref)
  if (original) return original
  const name = lastPathComponent(ref)
  return name === '' ? ref : name
}

// MARK: - Injected context (HermesKit's `InjectedContext`)

const attachedContextMarker = '--- Attached Context ---'
const contextWarningsMarker = '--- Context Warnings ---'
const hintPrefix = '[Image attached at: '
export const imagePlaceholders = new Set(['[screenshot]', '[image]'])

/** The text the user sent, and the image paths the hints name, in order. */
export function userTurn(text: string): { text: string; imagePaths: string[] } {
  return splitImageHints(strippingAttachedContext(strippingMemoryContext(text)))
}

function hintPath(line: string): string | undefined {
  const trimmed = line.replace(/^[ \t]+|[ \t]+$/g, '')
  if (!trimmed.startsWith(hintPrefix) || !trimmed.endsWith(']')) return undefined
  const path = trimmed.slice(hintPrefix.length, -1)
  return path === '' || path.includes(']') ? undefined : path
}

function isAppendedAfterExpansion(line: string): boolean {
  const trimmed = line.replace(/^[ \t]+|[ \t]+$/g, '')
  return trimmed === '' || imagePlaceholders.has(trimmed) || hintPath(line) !== undefined
    || imageDirectivePath(line) !== undefined
}

function blockReference(line: string): string | undefined {
  for (const icon of ['📄 ', '📁 ']) {
    if (!line.startsWith(icon)) continue
    const header = line.slice(icon.length)
    if (!attachmentPrefixes.some((prefix) => header.startsWith(prefix)) || !header.endsWith(' tokens)')) return undefined
    const count = header.lastIndexOf(' (')
    if (count < 0) return undefined
    return header.slice(0, count)
  }
  return undefined
}

/** The prompt without the expansion of its `@file:` references, as Desktop shows it. */
export function strippingAttachedContext(text: string): string {
  if (!text.includes(attachedContextMarker) && !text.includes(contextWarningsMarker)) return text
  const lines = text.split('\n')
  const trailer: string[] = []
  while (lines.length > 0 && isAppendedAfterExpansion(lines[lines.length - 1]!)) trailer.unshift(lines.pop()!)
  const trim = (line: string) => line.replace(/^[ \t]+|[ \t]+$/g, '')
  const attached = lines.findIndex((line) => trim(line) === attachedContextMarker)
  const shown = attached >= 0 ? lines.slice(0, attached) : lines
  const warnings = shown.findIndex((line) => trim(line) === contextWarningsMarker)
  if (attached < 0 && warnings < 0) return text
  const prompt = (warnings >= 0 ? shown.slice(0, warnings) : shown).join('\n').trim()
  const missing: string[] = []
  if (attached >= 0) {
    for (const line of lines.slice(attached)) {
      const reference = blockReference(line)
      if (reference !== undefined && !prompt.includes(reference) && !missing.includes(reference)) missing.push(reference)
    }
  }
  const shownText = [missing.join('\n'), prompt].filter((part) => part !== '').join('\n\n')
  let start = 0
  while (start < trailer.length && trim(trailer[start]!) === '') start += 1
  return [shownText, ...trailer.slice(start)].join('\n')
}

const closedBlock = /<\s*memory-context\s*>[\s\S]*?<\/\s*memory-context\s*>/gi
const openBlock = /<\s*memory-context\s*>[\s\S]*$/gi
const systemNote = /\[System note:\s*The following is recalled memory context,\s*NOT new user input\.\s*Treat as (?:informational background data|authoritative reference data[^\]]*)\.\]\s*/gi
const fenceTag = /<\/?\s*memory-context\s*>/gi

/** `sanitize_context` (`agent/memory_manager.py:165-177`). */
export function strippingMemoryContext(text: string): string {
  if (!/memory-context/i.test(text) && !text.includes('[System note:')) return text
  let stripped = text
  for (const pattern of [closedBlock, openBlock, systemNote, fenceTag]) stripped = stripped.replace(pattern, '')
  return stripped === text ? text : stripped.trim()
}

/** The trailing `[Image attached at: …]` hints lifted off as paths. */
export function splitImageHints(text: string): { text: string; imagePaths: string[] } {
  if (!text.includes(hintPrefix)) return { text, imagePaths: [] }
  const lines = text.split('\n')
  while (lines.length > 0) {
    const last = lines[lines.length - 1]!.replace(/^[ \t]+|[ \t]+$/g, '')
    if (last === '' || imagePlaceholders.has(last)) lines.pop()
    else break
  }
  const paths: string[] = []
  while (lines.length > 0) {
    const path = hintPath(lines[lines.length - 1]!)
    if (path === undefined) break
    paths.unshift(path)
    lines.pop()
  }
  if (paths.length === 0) return { text, imagePaths: [] }
  const caption = lines.join('\n').trim()
  return { text: caption === defaultImageQuestion ? '' : caption, imagePaths: paths }
}
