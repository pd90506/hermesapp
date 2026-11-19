import { describe, expect, test } from 'vitest'
import fixture from '../../../fixtures/appearance-themes.json' with { type: 'json' }
import {
  AppearanceSettings, MarkdownColors, colorThemeLabel, colorThemes, hexColor, markdownElements, markdownPalette, mix,
  parseHex, themeAccent, themeSurfaces, tintedSurfaces, toHex, type ColorPair, type ColorTheme, type TextKind,
  type ThemeSurfaces,
} from '../../src/index.ts'

// The same file as HermesKit's AppearanceFixtureTests.swift (Packages/fixtures/README.md).

const hex = (pair: ColorPair | undefined) => (pair ? { light: toHex(pair.light), dark: toHex(pair.dark) } : null)
const surfaces = (each: ThemeSurfaces) => ({
  frame: hex(each.frame), chrome: hex(each.chrome), chat: hex(each.chat), composer: hex(each.composer),
  selection: hex(each.selection), userBubble: hex(each.userBubble),
})

describe('appearance-themes.json', () => {
  test('names every theme, in HermesKit order', () => {
    expect(fixture.themes.map((item) => item.theme)).toEqual([...colorThemes])
  })

  test.each(fixture.themes)('$theme: accent, surfaces and Markdown colours', (item) => {
    const theme = item.theme as ColorTheme
    expect(hex(themeAccent(theme))).toEqual(item.accent)
    expect(surfaces(themeSurfaces(theme))).toEqual(item.surfaces)
    const markdown = Object.fromEntries(markdownElements.map((element) => [element, hex(markdownPalette(theme)[element])]))
    expect(markdown).toEqual(item.markdown)
  })

  test.each(fixture.tintedPlain)('System tinted with $accent.light', (item) => {
    const accent = { light: hexColor(item.accent.light), dark: hexColor(item.accent.dark) }
    expect(surfaces(tintedSurfaces('plain', accent))).toEqual(item.surfaces)
  })

  test.each(fixture.appearanceSettings)('loads $json', (item) => {
    expect(AppearanceSettings.fromJSON(item.json).toJSON()).toEqual(item.decoded)
  })

  test.each(fixture.setSize)('sets $kind to $size', (item) => {
    const settings = AppearanceSettings.default.withSize(item.kind as TextKind, item.size, item.platformDefault)
    if (item.saved === null) expect(settings.isCustom(item.kind as TextKind)).toBe(false)
    else expect(settings.size(item.kind as TextKind, item.platformDefault)).toBe(item.saved)
  })
})

describe('colours', () => {
  test('hex round trip, alpha only when not opaque', () => {
    expect(toHex(hexColor('#0053fd'))).toBe('#0053FD')
    expect(toHex(hexColor('0053FD80'))).toBe('#0053FD80')
    expect(parseHex('#12345')).toBeUndefined()
    expect(parseHex('#GG0000')).toBeUndefined()
  })

  test('a mix rounds to 8 bits a channel', () => {
    expect(toHex(mix(hexColor('#F6F8FA'), hexColor('#0053FD'), 0.08))).toBe('#E2EBFA')
  })

  test('System has no accent of its own and is labelled System', () => {
    expect(themeAccent('plain')).toBeUndefined()
    expect(colorThemeLabel('plain')).toBe('System')
    expect(colorThemeLabel('claudeCode')).toBe('Claude Code')
  })
})

describe('MarkdownColors', () => {
  test('defaults to Nous, its link the accent', () => {
    expect(MarkdownColors.default.preset).toBe('nous')
    expect(toHex(MarkdownColors.default.color('link', 'light'))).toBe(toHex(themeAccent('nous')!.light))
  })

  test('a changed colour sticks until the preset changes; the preset colour forgets it', () => {
    const red = hexColor('#FF0000')
    let colors = MarkdownColors.of('catppuccin').withColor(red, 'heading', 'light')
    expect(colors.isCustom('heading')).toBe(true)
    expect(MarkdownColors.fromJSON(colors.toJSON()).equals(colors)).toBe(true)
    colors = colors.withColor(markdownPalette('catppuccin').heading.light, 'heading', 'light')
    expect(colors.hasCustomColors).toBe(false)
    expect(colors.withColor(red, 'link', 'dark').choose('github').hasCustomColors).toBe(false)
    expect(colors.withColor(red, 'link', 'dark').resetColors().preset).toBe('catppuccin')
  })

  test('loads what another version saved', () => {
    const colors = MarkdownColors.fromJSON({ preset: 'everforest', colors: { heading: { light: '#FF0000', sepia: '#00FF00' }, nope: {}, link: { dark: 'bad' } } })
    expect(colors.preset).toBe('everforest')
    expect(colors.toJSON()).toEqual({ preset: 'everforest', colors: { heading: { light: '#FF0000' } } })
    expect(MarkdownColors.fromJSON({ preset: 'unknown' }).preset).toBe('nous')
    expect(MarkdownColors.fromJSON(null).preset).toBe('nous')
  })
})

describe('AppearanceSettings', () => {
  test('defaults: the system look, the Mac sizes', () => {
    const settings = AppearanceSettings.default
    expect(settings.mode).toBe('system')
    expect([settings.size('ui'), settings.size('content'), settings.size('code')]).toEqual([14, 14, 12])
    expect(settings.isDefault).toBe(true)
  })

  test('Restore Defaults forgets the look and the sizes', () => {
    const changed = AppearanceSettings.default.withMode('dark').withSize('code', 16)
    expect(changed.isDefault).toBe(false)
    expect(changed.reset().equals(AppearanceSettings.default)).toBe(true)
  })
})
