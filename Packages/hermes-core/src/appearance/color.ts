/**
 * A colour in sRGB, each channel kept to 8 bits, as HermesKit's `RGBAColor`
 * (`Sources/HermesKit/Appearance/MarkdownColors.swift`): the same rounding, so a mix
 * here gives the very colour the Mac and iOS apps draw.
 */
export interface RGBAColor {
  readonly red: number
  readonly green: number
  readonly blue: number
  readonly alpha: number
}

/** Each channel clamped to 0…1 and rounded to the nearest 1/255. */
export function rgba(red: number, green: number, blue: number, alpha = 1): RGBAColor {
  const channel = (value: number) => (Number.isFinite(value) ? Math.round(Math.min(Math.max(value, 0), 1) * 255) / 255 : 0)
  return { red: channel(red), green: channel(green), blue: channel(blue), alpha: channel(alpha) }
}

/** `#RRGGBB` or `#RRGGBBAA`, the `#` optional; undefined for anything else. */
export function parseHex(hex: string): RGBAColor | undefined {
  let digits = hex.trim()
  if (digits.startsWith('#')) digits = digits.slice(1)
  if ((digits.length !== 6 && digits.length !== 8) || !/^[0-9a-f]+$/i.test(digits)) return undefined
  const full = digits.length === 6 ? `${digits}ff` : digits
  const byte = (index: number) => Number.parseInt(full.slice(index * 2, index * 2 + 2), 16) / 255
  return rgba(byte(0), byte(1), byte(2), byte(3))
}

/** Like `parseHex`, for the colours written in this package: throws on a typo. */
export function hexColor(hex: string): RGBAColor {
  const color = parseHex(hex)
  if (!color) throw new Error(`Not a #RRGGBB(AA) colour: ${hex}`)
  return color
}

/** `#RRGGBB` when opaque, else `#RRGGBBAA`, in capitals. */
export function toHex(color: RGBAColor): string {
  const bytes = [color.red, color.green, color.blue, color.alpha].map((value) => Math.round(value * 255))
  const shown = bytes[3] === 255 ? bytes.slice(0, 3) : bytes
  return `#${shown.map((value) => value.toString(16).padStart(2, '0').toUpperCase()).join('')}`
}

/** `color` with `amount` (0…1) of `other` mixed in, in sRGB (`RGBAColor.mixed`). */
export function mix(color: RGBAColor, other: RGBAColor, amount: number): RGBAColor {
  const blend = (a: number, b: number) => a + (b - a) * amount
  return rgba(blend(color.red, other.red), blend(color.green, other.green), blend(color.blue, other.blue),
    blend(color.alpha, other.alpha))
}

export function sameColor(a: RGBAColor, b: RGBAColor): boolean {
  return toHex(a) === toHex(b)
}

/** A colour for light mode and one for dark (`MarkdownColors.Pair`). */
export interface ColorPair {
  readonly light: RGBAColor
  readonly dark: RGBAColor
}

export type ColorMode = 'light' | 'dark'

export function pair(light: string, dark: string): ColorPair {
  return { light: hexColor(light), dark: hexColor(dark) }
}
