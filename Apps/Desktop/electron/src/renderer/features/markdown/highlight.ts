import type { HighlighterCore, ThemedToken } from 'shiki/core'

/**
 * Syntax colours for code fences, by Shiki with the official Desktop's themes
 * (`shiki-config.ts`: GitHub Light Default, GitHub Dark Dimmed), both at once as CSS
 * variables so a switch to dark needs no new pass. Shiki and each language load on first
 * use, in their own chunks: none of it is on the window's start-up path. The JavaScript
 * regex engine runs under the page's CSP, which allows no WebAssembly.
 */
export interface HighlightedLine {
  tokens: { content: string; light?: string; dark?: string }[]
}

const themes = { light: 'github-light-default', dark: 'github-dark-dimmed' } as const
/** GitHub Light's comment grey is too faint at code size (the official Desktop's fix). */
const colorReplacements = { 'github-light-default': { '#6e7781': '#57606a' } }

let highlighter: Promise<HighlighterCore> | undefined
const loading = new Map<string, Promise<boolean>>()
const cache = new Map<string, HighlightedLine[]>()
const cacheLimit = 256

async function load(): Promise<HighlighterCore> {
  const [{ createHighlighterCore }, { createJavaScriptRegexEngine }, light, dark] = await Promise.all([
    import('shiki/core'),
    import('shiki/engine/javascript'),
    import('shiki/themes/github-light-default.mjs'),
    import('shiki/themes/github-dark-dimmed.mjs'),
  ])
  return createHighlighterCore({
    themes: [light.default, dark.default],
    langs: [],
    engine: createJavaScriptRegexEngine({ forgiving: true }),
  })
}

/** Loads the fence's language; false for one Shiki does not know. */
async function language(core: HighlighterCore, name: string): Promise<string | undefined> {
  const { bundledLanguages, bundledLanguagesAlias } = await import('shiki/langs')
  const id = name in bundledLanguages ? name : name in bundledLanguagesAlias ? name : undefined
  if (!id) return undefined
  let pending = loading.get(id)
  if (!pending) {
    const loader = (bundledLanguages as Record<string, () => Promise<{ default: unknown }>>)[id]
      ?? (bundledLanguagesAlias as Record<string, () => Promise<{ default: unknown }>>)[id]
    pending = loader
      ? loader().then(async (module) => {
        await core.loadLanguage(module.default as Parameters<HighlighterCore['loadLanguage']>[0])
        return true
      }).catch(() => false)
      : Promise.resolve(false)
    loading.set(id, pending)
  }
  return (await pending) ? id : undefined
}

function key(code: string, lang: string): string {
  return `${lang}\u0001${code}`
}

/** A highlight already made, so a block that scrolls back into view draws coloured at once. */
export function cachedHighlight(code: string, lang: string | undefined): HighlightedLine[] | undefined {
  return lang ? cache.get(key(code, lang)) : undefined
}

/** The fence's lines in colour, or undefined when the language is unknown. */
export async function highlight(code: string, lang: string | undefined): Promise<HighlightedLine[] | undefined> {
  if (!lang) return undefined
  const cached = cache.get(key(code, lang))
  if (cached) return cached
  highlighter ??= load()
  const core = await highlighter
  const id = await language(core, lang)
  if (!id) return undefined
  const result = core.codeToTokens(code, { lang: id, themes, defaultColor: false, colorReplacements })
  const lines = result.tokens.map((line: ThemedToken[]) => ({
    tokens: line.map((token) => ({
      content: token.content,
      light: token.htmlStyle?.['--shiki-light'],
      dark: token.htmlStyle?.['--shiki-dark'],
    })),
  }))
  if (cache.size >= cacheLimit) cache.delete(cache.keys().next().value ?? '')
  cache.set(key(code, lang), lines)
  return lines
}
