import { mix, pair, type ColorPair } from './color.ts'

/**
 * The app's colour theme (Settings ▸ Appearance ▸ Theme), HermesKit's `ColorTheme`:
 * an accent, the window's surfaces, and the Markdown colours of replies. The raw
 * values are Swift's case names, which the saved settings use. `plain` is "System".
 */
export const colorThemes = ['nous', 'github', 'catppuccin', 'everforest', 'solarized', 'codex', 'claudeCode', 'plain'] as const

export type ColorTheme = (typeof colorThemes)[number]

/** The names the picker shows (`ColorThemePicker.label`). */
export function colorThemeLabel(theme: ColorTheme): string {
  switch (theme) {
    case 'nous': return 'Nous'
    case 'github': return 'GitHub'
    case 'catppuccin': return 'Catppuccin'
    case 'everforest': return 'Everforest'
    case 'solarized': return 'Solarized'
    case 'codex': return 'Codex'
    case 'claudeCode': return 'Claude Code'
    case 'plain': return 'System'
  }
}

/** The accent in light and dark; undefined follows the system's accent. */
export function themeAccent(theme: ColorTheme): ColorPair | undefined {
  switch (theme) {
    case 'nous': return pair('#0053FD', '#4A84FE')
    case 'github': return pair('#196D31', '#4F9E5E')
    case 'catppuccin': return pair('#6D2EBF', '#CBA6F7')
    case 'everforest': return pair('#586B35', '#A7C080')
    case 'solarized': return pair('#675E34', '#6EA1C4')
    case 'codex': return pair('#0169CC', '#339CFF')
    case 'claudeCode': return pair('#C15F3C', '#D97757')
    case 'plain': return undefined
  }
}

/** A theme's surfaces (`ThemeSurfaces`), each in light and dark. */
export interface ThemeSurfaces {
  /** The strip along the top and the profile rail (the iOS drawer's glass tint). */
  frame: ColorPair
  /** Under the session list and around the chat. */
  chrome: ColorPair
  /** The chat. */
  chat: ColorPair
  /** The composer's field, on the chat. */
  composer: ColorPair
  /** A selected sidebar row; undefined is the system's (the accent at 20%). */
  selection?: ColorPair
  /** The user's messages; undefined is the system's (the accent at 15%). */
  userBubble?: ColorPair
}

/** The neutrals from Hermes Desktop's palette (`palette` in ColorTheme.swift). */
function palette(theme: ColorTheme): ThemeSurfaces {
  const surfaces = (chrome: ColorPair, chat: ColorPair, composer: ColorPair, userBubble?: ColorPair): ThemeSurfaces =>
    ({ frame: chrome, chrome, chat, composer, ...(userBubble ? { userBubble } : {}) })
  switch (theme) {
    case 'nous': return surfaces(pair('#F6F8FA', '#010409'), pair('#FFFFFF', '#0D1117'), pair('#FFFFFF', '#1A1E24'), pair('#DAE7FD', '#17243A'))
    case 'github': return surfaces(pair('#F6F8FA', '#010409'), pair('#FFFFFF', '#0D1117'), pair('#FFFFFF', '#1A1E24'), pair('#DBE7E2', '#192A24'))
    case 'catppuccin': return surfaces(pair('#E6E9EF', '#181825'), pair('#EFF1F5', '#1E1E2E'), pair('#F7F8FA', '#29293A'), pair('#DCD7EE', '#38324B'))
    case 'everforest': return surfaces(pair('#EFEBD4', '#232A2E'), pair('#FDF6E3', '#2D353B'), pair('#FEFBF1', '#343F44'), pair('#EDE9D2', '#434E47'))
    case 'solarized': return surfaces(pair('#EEE8D5', '#001F26'), pair('#FDF6E3', '#002B36'), pair('#FEFBF1', '#073642'), pair('#EEE8D5', '#144050'))
    case 'codex': return surfaces(pair('#F9F9F9', '#0D0D0D'), pair('#FFFFFF', '#232323'), pair('#FFFFFF', '#2F2F2F'), pair('#F2F2F2', '#363636'))
    case 'claudeCode': return surfaces(pair('#F0EEE6', '#1F1E1D'), pair('#FAF9F5', '#262624'), pair('#FFFFFF', '#30302E'), pair('#EDE9DE', '#3A3936'))
    case 'plain': return surfaces(pair('#F4F4F5', '#161618'), pair('#FFFFFF', '#1E1E20'), pair('#FFFFFF', '#2A2A2D'))
  }
}

/** How much of the accent the chrome takes. */
const chromeTint = { light: 0.08, dark: 0.12 }

/** The colour the surfaces take: the accent, but Codex a graphite grey. */
function surfaceTint(theme: ColorTheme): ColorPair | undefined {
  return theme === 'codex' ? pair('#5C5C5C', '#8F8F8F') : themeAccent(theme)
}

/** The theme's surfaces, tinted with its accent (`ColorTheme.surfaces`). */
export function themeSurfaces(theme: ColorTheme): ThemeSurfaces {
  return tintedSurfaces(theme, surfaceTint(theme))
}

/**
 * The surfaces tinted with `accent` (`ColorTheme.surfaces(accent:)`): System passes
 * the system's accent, which only the app knows. Without one, the palette's neutrals.
 */
export function tintedSurfaces(theme: ColorTheme, accent: ColorPair | undefined): ThemeSurfaces {
  const surfaces = palette(theme)
  if (!accent) return surfaces
  const tint = (color: ColorPair, light: number, dark: number): ColorPair =>
    ({ light: mix(color.light, accent.light, light), dark: mix(color.dark, accent.dark, dark) })
  const frame = tint(tint(surfaces.chrome, chromeTint.light, 0), 0.14, 0.24)
  const chrome = tint(surfaces.chrome, chromeTint.light, chromeTint.dark)
  return {
    ...surfaces,
    frame,
    chrome,
    selection: tint(chrome, 0.14, 0.22),
    userBubble: surfaces.userBubble ?? tint(surfaces.chat, 0.12, 0.18),
  }
}
