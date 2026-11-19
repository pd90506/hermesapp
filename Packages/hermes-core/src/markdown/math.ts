/**
 * Rewrites the maths in a message into the form the renderer's Markdown parser reads
 * (remark-math with single-dollar inline maths), with HermesKit's rules for what counts
 * as maths (`InlineParser`, `MarkdownParser`), so the desktop app and the Mac app agree:
 *
 * - Delimiters: `$…$` and `\(…\)` inline; `$$…$$` and `\[…\]` display; a line that
 *   starts `\begin{equation}` (or another maths environment) opens a display block that
 *   keeps its `\begin…\end`.
 * - A line that is only display maths (`$$ y $$`, `\[ x \]`, or an opener whose closer
 *   comes on a later line) becomes a display block; `$$a$$ and more` stays inline, in
 *   display style (`\displaystyle`).
 * - A single `$` follows Pandoc's rule, so prices don't turn into maths: the opener is
 *   followed by a non-space, the closer preceded by a non-space and not followed by a
 *   digit; the first unescaped `$` after an opener decides; maths never spans a
 *   backtick; `$` + digit with CJK text before the closer is a price (`成本是$5，而$x$`);
 *   `$` + an all-caps name followed by `/` or `:` is a shell variable (`$HOME/$USER`).
 *   A `$` that is not maths is escaped (`\$`), so the parser shows it as written.
 * - Code (fences and code spans) is left alone.
 *
 * While `streaming`, a display opener whose closer has not arrived yet still opens a
 * block (the Mac shows the formula as it grows); otherwise such a line stays text.
 */
export function normalizeMath(source: string, options: { streaming?: boolean } = {}): string {
  if (!/[$\\]/.test(source)) return source
  const lines = source.split('\n')
  const out: string[] = []
  let fence: { char: string; length: number } | undefined

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? ''
    if (fence) {
      out.push(line)
      const close = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line)
      if (close?.[1] && close[1][0] === fence.char && close[1].length >= fence.length) fence = undefined
      continue
    }
    const open = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
    if (open?.[1] && !(open[1][0] === '`' && open[2]?.includes('`'))) {
      fence = { char: open[1][0] ?? '`', length: open[1].length }
      out.push(line)
      continue
    }
    const block = displayBlock(lines, i, options.streaming ?? false)
    if (block) {
      out.push(block.indent + '$$', block.content, block.indent + '$$')
      if (block.rest !== undefined) {
        // Text after the closer continues as a new line.
        lines[block.end] = block.indent + block.rest
        i = block.end - 1
      } else {
        i = block.end
      }
      continue
    }
    out.push(inlineMath(line))
  }
  return out.join('\n')
}

/** HermesKit's `MarkdownParser.mathEnvironments`. */
const mathEnvironments = new Set([
  'equation', 'equation*', 'align', 'align*', 'gather', 'gather*', 'multline', 'multline*',
  'eqnarray', 'eqnarray*', 'flalign', 'flalign*', 'alignat', 'alignat*', 'displaymath',
])

function delimiters(trimmed: string): { open: string; close: string } | undefined {
  if (trimmed.startsWith('$$')) return { open: '$$', close: '$$' }
  if (trimmed.startsWith('\\[')) return { open: '\\[', close: '\\]' }
  const environment = /^\\begin\{([^}]*)\}/.exec(trimmed)
  if (environment?.[1] && mathEnvironments.has(environment[1])) return { open: '', close: `\\end{${environment[1]}}` }
  return undefined
}

interface DisplayBlock {
  indent: string
  content: string
  /** The last line the block takes. */
  end: number
  /** Text after the closer on that line, which continues as its own line. */
  rest?: string
}

function displayBlock(lines: string[], start: number, streaming: boolean): DisplayBlock | undefined {
  const line = lines[start] ?? ''
  const indent = /^ */.exec(line)?.[0] ?? ''
  if (indent.length > 3) return undefined
  const trimmed = line.trim()
  const marks = delimiters(trimmed)
  if (!marks) return undefined
  // `$$a$$ and more`: inline maths in a paragraph.
  const first = trimmed.slice(marks.open.length)
  const sameLine = marks.open ? first.indexOf(marks.close) : -1
  if (sameLine >= 0 && first.slice(sameLine + marks.close.length).trim() !== '') return undefined

  let text = first
  let from = 0
  for (let i = start; ; ) {
    const close = text.indexOf(marks.close, from)
    if (close >= 0) {
      const end = marks.open ? close : close + marks.close.length
      const rest = text.slice(close + marks.close.length).trim()
      const content = text.slice(0, end).trim()
      if (!content) return undefined
      return rest ? { indent, content, end: i, rest } : { indent, content, end: i }
    }
    i += 1
    if (i >= lines.length) break
    // The closer cannot straddle a line break, so only search the new line.
    from = text.length + 1
    text += '\n' + (lines[i] ?? '')
  }
  if (!streaming) return undefined
  let content = text.trim()
  // A half-typed closing `$` is not part of the formula.
  if (marks.open === '$$' && content.endsWith('$')) content = content.slice(0, -1).trimEnd()
  return content ? { indent, content, end: lines.length - 1 } : undefined
}

/** HermesKit's `Character.isCJK`. */
function isCJK(char: string): boolean {
  const code = char.codePointAt(0) ?? 0
  return (code >= 0x2e80 && code <= 0x9fff) || (code >= 0xac00 && code <= 0xd7af) || (code >= 0xf900 && code <= 0xfaff)
    || (code >= 0xfe30 && code <= 0xfe4f) || (code >= 0xff00 && code <= 0xffef)
}

const isSpace = (char: string | undefined) => char !== undefined && /\s/.test(char)
const isDigit = (char: string | undefined) => char !== undefined && /\p{Nd}/u.test(char)

/** One line's inline maths, as `InlineParser` reads it. */
export function inlineMath(line: string): string {
  if (!/[$\\]/.test(line)) return line
  const chars = Array.from(line)
  const look = new Lookahead(chars)
  let out = ''
  let i = 0
  while (i < chars.length) {
    const char = chars[i]
    const next = chars[i + 1]
    if (char === '\\') {
      if (next === '(' || next === '[') {
        const closer = next === '(' ? ')' : ']'
        const close = look.next(closer, i + 2, false,
          (j) => chars[j] === '`' || (chars[j] === '\\' && chars[j + 1] === closer))
        if (close !== undefined && chars[close] === '\\') {
          const content = chars.slice(i + 2, close).join('')
          if (content.trim()) {
            out += next === '(' ? `$${content}$` : `$\\displaystyle ${content}$`
            i = close + 2
            continue
          }
        }
      }
      out += char + (next ?? '')
      i += 2
      continue
    }
    if (char === '`') {
      let run = 1
      while (chars[i + run] === '`') run += 1
      const end = closingTicks(chars, i + run, run)
      const stop = end === undefined ? i + run : end + run
      out += chars.slice(i, stop).join('')
      i = stop
      continue
    }
    if (char === '$') {
      if (next === '$') {
        const close = look.next('$$', i + 2, true,
          (j) => chars[j] === '`' || (chars[j] === '$' && chars[j + 1] === '$'))
        const content = close !== undefined && chars[close] === '$' ? chars.slice(i + 2, close).join('') : ''
        if (close !== undefined && content.trim()) {
          out += `$\\displaystyle ${content}$`
          i = close + 2
          continue
        }
        out += '\\$\\$'
        i += 2
        continue
      }
      const close = closingDollar(chars, i, look)
      if (close !== undefined && chars.slice(i + 1, close).join('').trim()) {
        out += chars.slice(i, close + 1).join('')
        i = close + 1
        continue
      }
      out += '\\$'
      i += 1
      continue
    }
    out += char
    i += 1
  }
  return out
}

function closingDollar(chars: string[], opener: number, look: Lookahead): number | undefined {
  const first = chars[opener + 1]
  if (first === undefined || isSpace(first) || isShellVariable(chars, opener + 1)) return undefined
  const close = look.next('$', opener + 1, true, (j) => chars[j] === '$' || chars[j] === '`')
  if (close === undefined || chars[close] !== '$') return undefined
  if (isSpace(chars[close - 1]) || isDigit(chars[close + 1])) return undefined
  // `成本是$5，而$x$`: a price followed by CJK prose, not maths.
  if (isDigit(first) && chars.slice(opener + 1, close).some(isCJK)) return undefined
  return close
}

/** `$HOME/…`, `$PATH:…`: two or more capitals (then capitals, digits or `_`) directly followed by `/` or `:`. */
function isShellVariable(chars: string[], start: number): boolean {
  let j = start
  while (j < chars.length && /^[A-Z]$/.test(chars[j] ?? '')) j += 1
  if (j - start < 2) return false
  while (j < chars.length && /^[A-Z0-9_]$/.test(chars[j] ?? '')) j += 1
  return chars[j] === '/' || chars[j] === ':'
}

/** The start of a run of exactly `run` backticks at or after `from`. */
function closingTicks(chars: string[], from: number, run: number): number | undefined {
  let j = from
  while (j < chars.length) {
    if (chars[j] !== '`') { j += 1; continue }
    let length = 0
    while (chars[j + length] === '`') length += 1
    if (length === run) return j
    j += length
  }
  return undefined
}

/**
 * Forward searches, memoized per kind as HermesKit's `Lookahead` does, so a line of
 * many openers without closers stays linear rather than quadratic.
 */
class Lookahead {
  private memo = new Map<string, { from: number; found?: number }>()

  constructor(private readonly chars: string[]) {}

  next(key: string, start: number, skipEscapes: boolean, match: (j: number) => boolean): number | undefined {
    const previous = this.memo.get(key)
    if (previous && start >= previous.from) {
      if (previous.found === undefined) return undefined
      if (start <= previous.found) return previous.found
    }
    let j = start
    while (j < this.chars.length) {
      if (skipEscapes && this.chars[j] === '\\') { j += 2; continue }
      if (match(j)) {
        this.memo.set(key, { from: start, found: j })
        return j
      }
      j += 1
    }
    this.memo.set(key, { from: start })
    return undefined
  }
}
