import type { Bot } from '../bots.ts'

/**
 * A profile's avatar as Hermes stores it: an image in the profile's asset store
 * (`profiles.get_asset` / `profiles.set_asset`, `tui_gateway/methods_profiles.py:411-463`),
 * sent as a data URL. Hermes Desktop's Bots plugin uses the same asset (HermesKit's
 * `ProfileAvatar`).
 */
export const avatarMaxBytes = 2_000_000
/** The side of an uploaded avatar, as Desktop's picker makes it (`plugins/hermes-bots/avatar-image.ts:18`). */
export const avatarUploadEdge = 256

/** A `data:<mime>;base64,…` URL kept as it is, for an `<img>`; undefined when it isn't one. */
export function avatarDataURL(value: string | null | undefined): string | undefined {
  if (!value) return undefined
  if (/^data:image\/[\w.+-]+;base64,/.test(value)) return value
  if (/^[A-Za-z0-9+/=\s]+$/.test(value)) return `data:image/png;base64,${value.replace(/\s+/g, '')}`
  return undefined
}

export function hasAvatar(bot: Bot): boolean {
  return bot.profile.has_avatar === true
}

/** The avatar colour picked in Hermes Desktop (`ui_meta['hermes-bots'].color`), as `#rrggbb`. */
export function avatarColor(bot: Bot): string | undefined {
  const meta = bot.profile.ui_meta?.['hermes-bots']
  const raw = meta && typeof meta === 'object' && !Array.isArray(meta) ? meta.color : undefined
  if (typeof raw !== 'string') return undefined
  let hex = raw.trim()
  if (!hex.startsWith('#')) return undefined
  hex = hex.slice(1)
  if (hex.length === 3) hex = [...hex].map((digit) => digit + digit).join('')
  return /^[0-9a-f]{6}$/i.test(hex) ? `#${hex.toLowerCase()}` : undefined
}
