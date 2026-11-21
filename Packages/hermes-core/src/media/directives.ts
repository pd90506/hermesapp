/**
 * Transcript directives: `::name{key="value"}` in a reply, which a graphical chat draws as a
 * component in place (docs/protocol.md §10.11). Hermes' `desktop` system prompt teaches one,
 * `::preview{file="path.html"}`: an HTML file the agent wrote, shown live in the message
 * (`agent/prompt_builder.py`, PLATFORM_HINTS["desktop"]).
 *
 * Read as Desktop reads them (`apps/desktop/src/lib/transcript-directives.ts`): a directive
 * starts wherever a word can start (so `std::vector` never is one), only a name the app
 * claims is drawn (any other stays the text it was), and a brace the attributes could not
 * close leaves the whole thing as text. Attributes are untrusted model output.
 * `[client choice]` Directives in fenced code are examples and stay text, as `MEDIA:` tags
 * do, and while a reply streams a directive whose brace is still open on the last line waits.
 */

/** The directives this app draws. */
export const claimedDirectives: readonly string[] = ['preview']

/** Desktop's `DIRECTIVE_BODY_MAX`: room for two signed CDN URLs and a title. */
export const directiveBodyLimit = 2048

export interface TranscriptDirective {
  name: string
  /** Lowercased keys; values as written. */
  attrs: Record<string, string>
  /** The directive's text, for a fallback. */
  source: string
}

export type DirectiveSegment = { kind: 'markdown'; text: string } | ({ kind: 'directive' } & TranscriptDirective)

const segmentExpression = new RegExp(String.raw`(?<=^|\s)::([a-z][a-z0-9-]{0,63})(?:\{([^{}\n]{0,${directiveBodyLimit}})\})?`, 'g')
const openBrace = /(?<=^|\s)::[a-z][a-z0-9-]{0,63}\{[^{}]*$/
/** `key="value"`, single quotes accepted for model sloppiness (Desktop's `ATTR_RE`). */
const attrExpression = /([a-z][\w-]{0,63})=(?:"([^"]*)"|'([^']*)')/gi

export const TranscriptDirectives = {
  /** Whether a reply may hold a directive at all (a cheap check before splitting). */
  mayContain(text: string): boolean {
    return text.includes('::')
  },

  /** The reply split around the directives it holds, in order. */
  segments(text: string, isStreaming = false, claimed: readonly string[] = claimedDirectives): DirectiveSegment[] {
    if (!text.includes('::')) return text === '' ? [] : [{ kind: 'markdown', text }]
    let body = text
    if (isStreaming) {
      const lastLine = body.lastIndexOf('\n') + 1
      if (openBrace.test(body.slice(lastLine))) body = body.slice(0, lastLine)
    }
    const segments: DirectiveSegment[] = []
    let chunk: string[] = []
    const flush = () => {
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
      if (fenced || !line.includes('::')) {
        chunk.push(line)
        continue
      }
      let cursor = 0
      let rest = ''
      for (const match of line.matchAll(segmentExpression)) {
        const start = match.index ?? 0
        const name = match[1]!
        if (!claimed.includes(name)) continue
        // A brace the attributes refused: half a directive is not one.
        if (match[2] === undefined && line[start + match[0].length] === '{') continue
        const before = line.slice(cursor, start)
        if (before.trim() !== '') chunk.push(before.trimEnd())
        flush()
        segments.push({ kind: 'directive', name, attrs: parseAttrs(match[2]), source: match[0] })
        cursor = start + match[0].length
      }
      rest = line.slice(cursor)
      if (cursor === 0) chunk.push(line)
      else if (rest.trim() !== '') chunk.push(rest.trimStart())
    }
    flush()
    return segments
  },
}

function parseAttrs(body: string | undefined): Record<string, string> {
  const attrs: Record<string, string> = {}
  for (const pair of (body ?? '').matchAll(attrExpression)) {
    // Models copy the `<https://…>` autolink form into attributes too.
    attrs[pair[1]!.toLowerCase()] = (pair[2] ?? pair[3] ?? '').replace(/^<(https?:\/\/[^<>\s]+)>$/i, '$1')
  }
  return attrs
}

/** Where a `::preview` points: an HTML file to draw in place, another file, or a web page. */
export type PreviewTarget =
  | { kind: 'html'; path: string }
  | { kind: 'file'; path: string }
  | { kind: 'url'; url: string }

/** Desktop's `localPreviewTarget`, without the cwd join: the gateway resolves a relative path against the chat's folder. */
export function previewTarget(file: string | undefined): PreviewTarget | undefined {
  const raw = (file ?? '').trim().replace(/^`|`$/g, '')
  if (raw === '') return undefined
  if (/^https?:\/\//i.test(raw)) return { kind: 'url', url: raw }
  let path = raw
  if (/^file:\/\//i.test(raw)) {
    try {
      path = decodeURIComponent(new URL(raw).pathname)
      // `file:///C:/x` reads as `/C:/x`.
      if (/^\/[A-Za-z]:[/\\]/.test(path)) path = path.slice(1)
    } catch {
      path = raw.replace(/^file:\/\//i, '')
    }
  }
  return /\.(?:html?|xhtml)$/i.test(path) ? { kind: 'html', path } : { kind: 'file', path }
}

/** Whether a path is relative, so the gateway reads it against the chat's folder. */
export function isRelativePath(path: string): boolean {
  return !(path.startsWith('/') || path.startsWith('~') || /^[A-Za-z]:[/\\]/.test(path) || path.startsWith('\\\\'))
}
