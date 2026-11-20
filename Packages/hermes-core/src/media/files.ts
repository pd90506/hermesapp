import { attachmentDisplayName } from '../session/items.ts'
import { fileExtension, imageFileExtensions } from '../composer/attachments/policy.ts'

/** What a file is, by its extension: enough to pick an icon (HermesKit's `FileKind`). */
export type FileKind =
  | 'image' | 'pdf' | 'text' | 'code' | 'spreadsheet' | 'document' | 'presentation' | 'archive' | 'audio' | 'video' | 'other'

/** `/api/media`'s image types and what the composer sends (HermesKit's `TranscriptImage.imageExtensions`). */
export const transcriptImageExtensions = new Set([...imageFileExtensions, 'svg', 'ico'])

/** Whether `path` names an image by its extension: only those are read back as thumbnails. */
export function isImagePath(path: string): boolean {
  return transcriptImageExtensions.has(fileExtension(path))
}

const kinds: Record<string, FileKind> = {}
const add = (kind: FileKind, extensions: Iterable<string>) => { for (const ext of extensions) kinds[ext] = kind }
add('image', transcriptImageExtensions)
add('pdf', ['pdf'])
add('text', ['txt', 'md', 'markdown', 'rst', 'log', 'rtf'])
add('code', ['swift', 'py', 'js', 'ts', 'tsx', 'jsx', 'json', 'yaml', 'yml', 'toml', 'xml', 'html', 'htm', 'css',
  'sh', 'zsh', 'bash', 'c', 'h', 'cpp', 'hpp', 'm', 'mm', 'rs', 'go', 'java', 'kt', 'rb', 'php', 'sql',
  'ini', 'cfg', 'conf', 'diff', 'patch', 'ipynb'])
add('spreadsheet', ['csv', 'tsv', 'xls', 'xlsx', 'numbers', 'ods'])
add('document', ['doc', 'docx', 'pages', 'odt', 'epub'])
add('presentation', ['ppt', 'pptx', 'key', 'odp'])
add('archive', ['zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar'])
add('audio', ['mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg', 'opus', 'aiff'])
add('video', ['mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi'])

export function fileKind(filename: string): FileKind {
  return kinds[fileExtension(filename)] ?? 'other'
}

/** A file Hermes sent in a reply with a `MEDIA:<path>` tag: a path on the gateway's disk. */
export interface DeliveredFile {
  /** As the tag wrote it (absolute, `~/`, or relative to the session's folder). */
  path: string
}

export function deliveredFileName(file: DeliveredFile): string {
  return attachmentDisplayName(file.path)
}

/** A run of a reply as shown: Markdown, or the files delivered at that point. */
export type MediaSegment = { kind: 'markdown'; text: string } | { kind: 'files'; files: DeliveredFile[] }

/**
 * Hermes' `MEDIA_DELIVERY_EXTS` (`gateway/platforms/base.py:1289`, mirrored by Desktop's
 * `parts.ts:121-180`): an unquoted path may contain spaces only when it ends in one.
 */
const deliveryExtensions = [
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'tiff', 'svg',
  'mp4', 'mov', 'avi', 'mkv', 'webm', '3gp',
  'mp3', 'm2a', 'wav', 'ogg', 'opus', 'm4a', 'flac',
  'pdf', 'docx', 'doc', 'odt', 'rtf', 'txt', 'md', 'epub',
  'xlsx', 'xls', 'ods', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml',
  'kmz', 'kml', 'geojson', 'gpx',
  'pptx', 'ppt', 'odp', 'key',
  'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'apk', 'ipa',
  'html', 'htm',
]

const valuePattern = (() => {
  const alternation = [...deliveryExtensions].sort((a, b) => b.length - a.length).join('|')
  const anchored = String.raw`(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:` + alternation +
    String.raw`)(?=[\s\x60"'*_,;:)\]}]|MEDIA:|$)`
  return String.raw`(\x60[^\x60\n]+\x60|"[^"\n]+"|'[^'\n]+'|` + anchored + String.raw`|[^\s\x60"]+)`
})()

/** Desktop's `MEDIA_LINE_RE`: a tag alone on its line. */
const lineExpression = new RegExp(String.raw`(^|\n)[\t ]*[\x60"']?MEDIA:\s*` + valuePattern + String.raw`[\x60"']?[\t ]*(\n|$)`, 'g')
/** Desktop's `MEDIA_TAG_RE`: a tag anywhere. */
const tagExpression = new RegExp(String.raw`[\x60"']?MEDIA:\s*` + valuePattern + String.raw`[\x60"']?`, 'g')

const trailingPunctuation = new Set(['.', ',', ';', ':', '!', '?'])
const prefix = 'MEDIA:'

/**
 * `MEDIA:<path>` tags in assistant text: how Hermes delivers files to a graphical chat
 * (HermesKit's `MediaTags`, docs/protocol.md §10.10). Parsed as Desktop parses them
 * (`apps/desktop/src/lib/chat-messages/parts.ts`), except that a tag alone on its line
 * is removed and an inline one becomes the file's name, and the files show as cards
 * right after the line that held the tag. Tags in fenced code blocks are examples.
 */
export const MediaTags = {
  /**
   * The reply split where its files were delivered. While it streams, a tag on its
   * unfinished last line may be a partial path, so that line waits.
   */
  segments(text: string, isStreaming = false): MediaSegment[] {
    if (!text.includes(prefix)) return text === '' ? [] : [{ kind: 'markdown', text }]
    let body = text
    if (isStreaming) {
      const lastLine = body.lastIndexOf('\n') + 1
      if (body.slice(lastLine).includes(prefix)) body = body.slice(0, lastLine)
    }
    const segments: MediaSegment[] = []
    let chunk: string[] = []
    const seen = new Set<string>()
    const flushText = () => {
      const markdown = chunk.join('\n').trim()
      chunk = []
      if (markdown !== '') segments.push({ kind: 'markdown', text: markdown })
    }
    let fenced = false
    for (const line of body.split('\n')) {
      if (line.trim().startsWith('```')) {
        fenced = !fenced
        chunk.push(line)
        continue
      }
      if (fenced || !line.includes(prefix)) {
        chunk.push(line)
        continue
      }
      const found: DeliveredFile[] = []
      const shown = rewrite(line, found)
      const files = found.filter((file) => {
        if (seen.has(file.path)) return false
        seen.add(file.path)
        return true
      })
      if (shown.trim() !== '') chunk.push(shown)
      if (files.length === 0) continue
      flushText()
      const last = segments[segments.length - 1]
      if (last?.kind === 'files') last.files.push(...files)
      else segments.push({ kind: 'files', files })
    }
    flushText()
    return segments
  },

  /** The text to show and the files it delivers, in order, each once. */
  extract(text: string, isStreaming = false): { text: string; files: DeliveredFile[] } {
    if (!text.includes(prefix)) return { text, files: [] }
    const markdown: string[] = []
    const files: DeliveredFile[] = []
    for (const segment of this.segments(text, isStreaming)) {
      if (segment.kind === 'markdown') markdown.push(segment.text)
      else files.push(...segment.files)
    }
    return { text: markdown.join('\n\n'), files }
  },
}

/** Lines with a tag alone go; other tags become the file's name. */
function rewrite(text: string, files: DeliveredFile[]): string {
  let result = text.replace(lineExpression, (match, lead: string, value: string, trailer: string) => {
    const file = fileFrom(value)
    if (!file) return match
    files.push(file.file)
    return lead === '' || trailer === '' ? lead + trailer : '\n'
  })
  result = result.replace(tagExpression, (match, value: string) => {
    const file = fileFrom(value)
    if (!file) return match
    files.push(file.file)
    return deliveredFileName(file.file) + file.punctuation
  })
  return result.replace(/\n{3,}/g, '\n\n')
}

/** A captured value as a file: quotes stripped; a bare value sheds trailing punctuation. */
function fileFrom(raw: string): { file: DeliveredFile; punctuation: string } | undefined {
  const value = raw.trim()
  let path: string
  let punctuation = ''
  const first = value[0]
  if (first !== undefined && '`"\''.includes(first) && value.length >= 2 && value[value.length - 1] === first) {
    path = value.slice(1, -1)
  } else {
    path = value
    const last = path[path.length - 1]
    if (last === '`' || last === '"') path = path.slice(0, -1)
    let end = path.length
    while (end > 0 && trailingPunctuation.has(path[end - 1]!) && isPlausible(path.slice(0, end - 1))) end -= 1
    punctuation = path.slice(end)
    path = path.slice(0, end)
  }
  if (!isPlausible(path)) return undefined
  return { file: { path }, punctuation }
}

/** A path separator, or a dot with something other than a dot after it. */
function isPlausible(value: string): boolean {
  if (value.includes('/') || value.includes('\\')) return true
  for (let index = 0; index + 1 < value.length; index += 1) {
    if (value[index] === '.' && value[index + 1] !== '.') return true
  }
  return false
}
