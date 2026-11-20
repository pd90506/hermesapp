import { readFileSync, readdirSync } from 'node:fs'
import { join, relative } from 'node:path'
import { describe, expect, it } from 'vitest'

// After deepseek-harness's ui-theme spec: components take colours and sizes from the
// tokens (theme/*.css) only, so the platforms and themes stay one design.
const renderer = join(import.meta.dirname, '../src/renderer')

function files(dir: string, suffix: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return files(path, suffix)
    return entry.name.endsWith(suffix) ? [path] : []
  })
}

function withoutComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, '')
}

describe('component stylesheets', () => {
  const sheets = files(renderer, '.module.css')

  it('exist', () => {
    expect(sheets.length).toBeGreaterThan(5)
  })

  it.each(sheets.map((path) => [relative(renderer, path), path]))('%s uses tokens for colours', (_name, path) => {
    const css = withoutComments(readFileSync(path, 'utf8'))
    expect(css).not.toMatch(/#[0-9a-f]{3,8}\b/i)
    expect(css).not.toMatch(/\b(rgba?|hsla?|oklch|lab|lch)\(/i)
    expect(css).not.toMatch(/:\s*(white|black)\b/i)
  })

  it.each(sheets.map((path) => [relative(renderer, path), path]))('%s uses tokens for sizes', (_name, path) => {
    const css = withoutComments(readFileSync(path, 'utf8'))
    const sizes = css.match(/(?<![\w-])\d*\.?\d+px\b/g) ?? []
    expect(sizes).toEqual([])
  })
})

describe('renderer code', () => {
  const sources = [...files(renderer, '.ts'), ...files(renderer, '.tsx')]

  it.each(sources.map((path) => [relative(renderer, path), path]))('%s never branches on the platform', (_name, path) => {
    const code = readFileSync(path, 'utf8')
    expect(code).not.toMatch(/platform\s*[!=]==/)
    expect(code).not.toMatch(/process\.platform|navigator\.(platform|userAgent)/)
  })
})

describe('tokens', () => {
  // Each package adds its own `:root` block; a name two of them define means the later
  // silently wins for both (G's prompt rail once narrowed the profile rail to 22 px).
  it('are each defined once at the top level', () => {
    const css = withoutComments(readFileSync(join(renderer, 'theme/tokens.css'), 'utf8'))
    const names = [...css.matchAll(/^:root\s*\{([^}]*)\}/gm)].flatMap((block) => [...block[1]!.matchAll(/(--[\w-]+)\s*:/g)].map((match) => match[1]!))
    expect(names.filter((name, index) => names.indexOf(name) !== index)).toEqual([])
  })
})
