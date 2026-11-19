import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
// @ts-expect-error: a plain ES module script, no types.
import { exportedStylesheet, stylesheetPath } from '../../scripts/export-themes.mjs'

describe('theme/themes/themes.css', () => {
  it('is what the export script makes of the HermesKit fixture', () => {
    // Out of date: run `node Apps/Desktop/electron/scripts/export-themes.mjs`.
    expect(readFileSync(stylesheetPath, 'utf8')).toBe(exportedStylesheet())
  })

  it('gives every colour theme its accent, surfaces and Markdown colours', () => {
    const css = exportedStylesheet() as string
    for (const theme of ['nous', 'github', 'catppuccin', 'everforest', 'solarized', 'codex', 'claudeCode']) {
      const rule = css.split(`:root[data-theme='${theme}'] {`)[1]?.split('}')[0] ?? ''
      for (const token of ['--accent', '--surface-chat', '--selection-fill', '--user-bubble', '--composer-fill', '--md-link']) {
        expect(rule, `${theme} ${token}`).toContain(`${token}:`)
      }
    }
  })

  it('leaves the System theme the platform surfaces', () => {
    const css = exportedStylesheet() as string
    const plain = css.split(":root[data-theme='plain'] {")[1]?.split('}')[0] ?? ''
    expect(plain).toContain('--md-link:')
    expect(plain).not.toContain('--surface-chat:')
    expect(plain).not.toContain('--accent:')
  })
})
