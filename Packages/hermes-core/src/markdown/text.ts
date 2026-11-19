/** A CJK language whose glyph forms Han characters take (the app's `data-cjk`). */
export type CJKLanguage = 'zh-Hans' | 'zh-Hant' | 'ja' | 'ko'

/**
 * The `lang` a message's text is marked with, so Chromium draws its Han characters in
 * their Chinese (or the system's) forms with the matching font, not the Japanese forms
 * an English page falls back to (the user, 2026-11-17). Kana make it Japanese and Hangul
 * Korean whatever the system's language; other Han text takes `preferred`. Undefined
 * for text without CJK characters, which keeps the page's language.
 */
export function cjkLanguageOf(text: string, preferred: CJKLanguage = 'zh-Hans'): CJKLanguage | undefined {
  if (/[぀-ヿㇰ-ㇿ]/.test(text)) return 'ja'
  if (/[가-힯ᄀ-ᇿ]/.test(text)) return 'ko'
  if (/\p{Script=Han}/u.test(text)) return preferred
  return undefined
}

/** Above this, a message shows as plain text: parsing it would stall the window. */
export const markdownCharacterLimit = 200_000

/**
 * The fence language, as written after the backticks (`language-ts` in the parsed
 * tree), lower-cased; undefined for a fence without one.
 */
export function fenceLanguage(className: string | undefined): string | undefined {
  const match = /(?:^|\s)language-([^\s]+)/.exec(className ?? '')
  return match?.[1]?.toLowerCase()
}

/** A minimal Markdown tree node, as remark builds them (mdast). */
export interface MarkdownNode {
  type: string
  value?: string
  children?: MarkdownNode[]
}

/**
 * Keeps every line break in a paragraph as a line break, as HermesKit's parser does
 * (CommonMark folds soft breaks into spaces, which suits neither chat text nor CJK).
 * A remark plugin: `remarkPlugins={[remarkKeepLineBreaks]}`.
 */
export function remarkKeepLineBreaks() {
  return (tree: MarkdownNode) => { keepBreaks(tree) }
}

function keepBreaks(node: MarkdownNode): void {
  const children = node.children
  if (!children) return
  if (!children.some((child) => child.type === 'text' && child.value?.includes('\n'))) {
    for (const child of children) keepBreaks(child)
    return
  }
  const next: MarkdownNode[] = []
  for (const child of children) {
    if (child.type !== 'text' || !child.value?.includes('\n')) {
      keepBreaks(child)
      next.push(child)
      continue
    }
    child.value.split(/[ \t]*\n[ \t]*/).forEach((part, index) => {
      if (index > 0) next.push({ type: 'break' })
      if (part) next.push({ type: 'text', value: part })
    })
  }
  node.children = next
}
