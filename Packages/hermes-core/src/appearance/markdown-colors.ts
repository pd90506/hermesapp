import { pair, parseHex, sameColor, toHex, type ColorMode, type ColorPair, type RGBAColor } from './color.ts'
import { colorThemes, type ColorTheme } from './color-theme.ts'

/** HermesKit's `MarkdownColors.Element`, in its order. */
export const markdownElements = [
  'heading', 'bold', 'link',
  'inlineCode', 'inlineCodeBackground', 'codeBlockBackground',
  'quoteBar', 'quoteText', 'quoteBackground',
  'tableHeaderBackground', 'tableHeaderText', 'tableBorder', 'tableStripe',
] as const

export type MarkdownElement = (typeof markdownElements)[number]

export type MarkdownPalette = Readonly<Record<MarkdownElement, ColorPair>>

type HexPalette = Record<MarkdownElement, [string, string]>

function palette(hex: HexPalette): MarkdownPalette {
  return Object.fromEntries(markdownElements.map((element) => [element, pair(...hex[element])])) as MarkdownPalette
}

/**
 * Each theme's Markdown colours, light then dark, copied from HermesKit's
 * `MarkdownColors` palettes (Hermes Desktop's themes, Codex, Claude Code, Plain).
 * `Packages/fixtures/appearance-themes.json` pins them to the Swift ones.
 */
const palettes: Record<ColorTheme, MarkdownPalette> = {
  nous: palette({
    heading: ['#0B3BA8', '#8DB2FF'],
    bold: ['#1F2328', '#F0F6FC'],
    link: ['#0053FD', '#4A84FE'],
    inlineCode: ['#B42D5B', '#FF8FB4'],
    inlineCodeBackground: ['#B42D5B14', '#FF8FB41F'],
    codeBlockBackground: ['#0053FD0D', '#4A84FE17'],
    quoteBar: ['#0053FDB3', '#4A84FECC'],
    quoteText: ['#57606A', '#9EA7B3'],
    quoteBackground: ['#0053FD0A', '#4A84FE12'],
    tableHeaderBackground: ['#0053FD1A', '#4A84FE29'],
    tableHeaderText: ['#0B3BA8', '#B5CDFF'],
    tableBorder: ['#0053FD33', '#4A84FE47'],
    tableStripe: ['#0053FD08', '#4A84FE0D'],
  }),
  github: palette({
    heading: ['#1F2328', '#F0F6FC'],
    bold: ['#1F2328', '#F0F6FC'],
    link: ['#0969DA', '#4493F8'],
    inlineCode: ['#1F2328', '#F0F6FC'],
    inlineCodeBackground: ['#818B9833', '#656C7666'],
    codeBlockBackground: ['#818B9817', '#0104094D'],
    quoteBar: ['#D1D9E0', '#3D444D'],
    quoteText: ['#59636E', '#9198A1'],
    quoteBackground: ['#00000000', '#00000000'],
    tableHeaderBackground: ['#818B9817', '#6E768126'],
    tableHeaderText: ['#1F2328', '#F0F6FC'],
    tableBorder: ['#D1D9E0', '#3D444D'],
    tableStripe: ['#818B980F', '#6E76811A'],
  }),
  catppuccin: palette({
    heading: ['#8839EF', '#CBA6F7'],
    bold: ['#4C4F69', '#CDD6F4'],
    link: ['#1E66F5', '#89B4FA'],
    inlineCode: ['#40A02B', '#A6E3A1'],
    inlineCodeBackground: ['#CCD0DA99', '#313244CC'],
    codeBlockBackground: ['#E6E9EFCC', '#181825B3'],
    quoteBar: ['#7287FD', '#B4BEFE'],
    quoteText: ['#6C6F85', '#A6ADC8'],
    quoteBackground: ['#7287FD0F', '#B4BEFE0F'],
    tableHeaderBackground: ['#8839EF1A', '#CBA6F726'],
    tableHeaderText: ['#8839EF', '#CBA6F7'],
    tableBorder: ['#BCC0CC', '#45475A'],
    tableStripe: ['#E6E9EF99', '#18182580'],
  }),
  everforest: palette({
    heading: ['#35A77C', '#A7C080'],
    bold: ['#5C6A72', '#D3C6AA'],
    link: ['#3A94C5', '#7FBBB3'],
    inlineCode: ['#E66E1A', '#E69875'],
    inlineCodeBackground: ['#F57D2617', '#E698751F'],
    codeBlockBackground: ['#EFEBD4B3', '#232A2EB3'],
    quoteBar: ['#8DA101', '#A7C080'],
    quoteText: ['#829181', '#9DA9A0'],
    quoteBackground: ['#8DA1010D', '#A7C08012'],
    tableHeaderBackground: ['#8DA1011F', '#A7C08026'],
    tableHeaderText: ['#5C6A72', '#D3C6AA'],
    tableBorder: ['#E0DCC7', '#4F585E'],
    tableStripe: ['#EFEBD480', '#2E383C80'],
  }),
  solarized: palette({
    heading: ['#CB4B16', '#CB4B16'],
    bold: ['#586E75', '#93A1A1'],
    link: ['#268BD2', '#268BD2'],
    inlineCode: ['#D33682', '#D33682'],
    inlineCodeBackground: ['#EEE8D5', '#073642'],
    codeBlockBackground: ['#EEE8D5B3', '#073642B3'],
    quoteBar: ['#2AA198', '#2AA198'],
    quoteText: ['#657B83', '#93A1A1'],
    quoteBackground: ['#2AA1980F', '#2AA1980F'],
    tableHeaderBackground: ['#EEE8D5', '#073642'],
    tableHeaderText: ['#586E75', '#93A1A1'],
    tableBorder: ['#E4DDC8', '#0B4452'],
    tableStripe: ['#EEE8D580', '#07364280'],
  }),
  codex: palette({
    heading: ['#0D0D0D', '#ECECEC'],
    bold: ['#0D0D0D', '#ECECEC'],
    link: ['#0169CC', '#48AAFF'],
    inlineCode: ['#0D0D0D', '#ECECEC'],
    inlineCodeBackground: ['#0D0D0D12', '#FFFFFF1A'],
    codeBlockBackground: ['#0D0D0D0A', '#0000004D'],
    quoteBar: ['#0D0D0D26', '#FFFFFF33'],
    quoteText: ['#5D5D5D', '#B4B4B4'],
    quoteBackground: ['#00000000', '#00000000'],
    tableHeaderBackground: ['#0D0D0D0A', '#FFFFFF0F'],
    tableHeaderText: ['#0D0D0D', '#ECECEC'],
    tableBorder: ['#0D0D0D1A', '#FFFFFF1F'],
    tableStripe: ['#00000000', '#00000000'],
  }),
  claudeCode: palette({
    heading: ['#141413', '#F5F4EE'],
    bold: ['#141413', '#F5F4EE'],
    link: ['#B4532F', '#E08A6D'],
    inlineCode: ['#9C3D1E', '#EBA58B'],
    inlineCodeBackground: ['#C15F3C14', '#D977571F'],
    codeBlockBackground: ['#E8E6DC99', '#1F1E1DB3'],
    quoteBar: ['#D97757', '#D97757'],
    quoteText: ['#73726C', '#A6A39A'],
    quoteBackground: ['#D977570A', '#D977570F'],
    tableHeaderBackground: ['#E8E6DCB3', '#30302ECC'],
    tableHeaderText: ['#141413', '#F5F4EE'],
    tableBorder: ['#DEDCD1', '#3E3E3A'],
    tableStripe: ['#F0EEE680', '#1F1E1D66'],
  }),
  plain: palette({
    heading: ['#000000D9', '#FFFFFFD9'],
    bold: ['#000000D9', '#FFFFFFD9'],
    link: ['#0068DA', '#419CFF'],
    inlineCode: ['#000000D9', '#FFFFFFD9'],
    inlineCodeBackground: ['#00000026', '#FFFFFF26'],
    codeBlockBackground: ['#0000000A', '#FFFFFF0A'],
    quoteBar: ['#00000042', '#FFFFFF40'],
    quoteText: ['#00000080', '#FFFFFF8C'],
    quoteBackground: ['#00000000', '#00000000'],
    tableHeaderBackground: ['#0000000F', '#FFFFFF0F'],
    tableHeaderText: ['#000000D9', '#FFFFFFD9'],
    tableBorder: ['#0000001A', '#FFFFFF1A'],
    tableStripe: ['#00000000', '#00000000'],
  }),
}

export function markdownPalette(theme: ColorTheme): MarkdownPalette {
  return palettes[theme]
}

/** How `MarkdownColors` is saved (Swift's Codable form): `{"preset", "colors": {element: {mode: hex}}}`. */
export interface MarkdownColorsJSON {
  preset: string
  colors: Record<string, Record<string, string>>
}

type Custom = Partial<Record<MarkdownElement, Partial<Record<ColorMode, RGBAColor>>>>

/**
 * The Markdown colours of replies: the app's theme (`preset`, Settings ▸ Appearance ▸
 * Theme) and any single colours the user changed (HermesKit's `MarkdownColors`).
 * Immutable: each change returns a new value.
 */
export class MarkdownColors {
  private constructor(readonly preset: ColorTheme, private readonly custom: Custom) {}

  static readonly default = new MarkdownColors('nous', {})

  static of(preset: ColorTheme): MarkdownColors {
    return new MarkdownColors(preset, {})
  }

  /** The colour of `element` in `mode`: the user's, or the preset's. */
  color(element: MarkdownElement, mode: ColorMode): RGBAColor {
    return this.custom[element]?.[mode] ?? palettes[this.preset][element][mode]
  }

  colors(element: MarkdownElement): ColorPair {
    return { light: this.color(element, 'light'), dark: this.color(element, 'dark') }
  }

  isCustom(element: MarkdownElement): boolean {
    return Object.keys(this.custom[element] ?? {}).length > 0
  }

  get hasCustomColors(): boolean {
    return markdownElements.some((element) => this.isCustom(element))
  }

  /** Sets one colour; the preset's own colour forgets it, so it follows the preset again. */
  withColor(color: RGBAColor, element: MarkdownElement, mode: ColorMode): MarkdownColors {
    const colors = { ...this.custom[element] }
    if (sameColor(color, palettes[this.preset][element][mode])) delete colors[mode]
    else colors[mode] = color
    const custom = { ...this.custom }
    if (Object.keys(colors).length === 0) delete custom[element]
    else custom[element] = colors
    return new MarkdownColors(this.preset, custom)
  }

  /** Switches to `preset` and forgets the colours the user changed. */
  choose(preset: ColorTheme): MarkdownColors {
    return new MarkdownColors(preset, {})
  }

  /** Every colour back to the preset's; the preset stays. */
  resetColors(): MarkdownColors {
    return new MarkdownColors(this.preset, {})
  }

  equals(other: MarkdownColors): boolean {
    return JSON.stringify(this.toJSON()) === JSON.stringify(other.toJSON())
  }

  toJSON(): MarkdownColorsJSON {
    const colors: MarkdownColorsJSON['colors'] = {}
    for (const element of markdownElements) {
      const modes = this.custom[element]
      if (!modes) continue
      const saved: Record<string, string> = {}
      for (const mode of ['light', 'dark'] as const) {
        const color = modes[mode]
        if (color) saved[mode] = toHex(color)
      }
      colors[element] = saved
    }
    return { preset: this.preset, colors }
  }

  /** Saved by another version: an unknown preset is the default, unknown elements and bad colours are dropped. */
  static fromJSON(json: unknown): MarkdownColors {
    const object = json && typeof json === 'object' ? (json as Record<string, unknown>) : {}
    const preset = colorThemes.find((theme) => theme === object.preset) ?? 'nous'
    const custom: Custom = {}
    const raw = object.colors && typeof object.colors === 'object' ? (object.colors as Record<string, unknown>) : {}
    for (const [key, modes] of Object.entries(raw)) {
      const element = markdownElements.find((each) => each === key)
      if (!element || !modes || typeof modes !== 'object') continue
      const colors: Partial<Record<ColorMode, RGBAColor>> = {}
      for (const [mode, hex] of Object.entries(modes as Record<string, unknown>)) {
        const color = typeof hex === 'string' ? parseHex(hex) : undefined
        if ((mode === 'light' || mode === 'dark') && color) colors[mode] = color
      }
      if (Object.keys(colors).length > 0) custom[element] = colors
    }
    return new MarkdownColors(preset, custom)
  }
}
