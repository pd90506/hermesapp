/**
 * The Appearance settings (HermesKit's `AppearanceSettings`): light, dark or the
 * system's look, and three text sizes. A size the user never changed is absent and
 * follows the platform default, so a later change to that default reaches it too.
 * Immutable: each change returns a new value. Saved in Swift's Codable form.
 */
export const appearanceModes = ['system', 'light', 'dark'] as const
export type AppearanceMode = (typeof appearanceModes)[number]

export const textKinds = ['ui', 'content', 'code'] as const
/** ui: sidebar, lists, tool rows, notices, settings. content: messages and the composer. code: code blocks. */
export type TextKind = (typeof textKinds)[number]

/** The sizes the steppers allow, in points. */
export const textSizeRange = { lower: 9, upper: 32 } as const

/**
 * The sizes before the user changes any: the Mac app's (14 pt UI and content, 12 pt
 * code, the user's choice, 2026-10), which are also Windows 11's body size.
 */
export const defaultTextSizes: Readonly<Record<TextKind, number>> = { ui: 14, content: 14, code: 12 }

export interface AppearanceSettingsJSON {
  theme: AppearanceMode
  sizes: Partial<Record<TextKind, number>>
}

export function appearanceModeLabel(mode: AppearanceMode): string {
  switch (mode) {
    case 'system': return 'System'
    case 'light': return 'Light'
    case 'dark': return 'Dark'
  }
}

export class AppearanceSettings {
  private constructor(readonly mode: AppearanceMode, private readonly sizes: Partial<Record<TextKind, number>>) {}

  static readonly default = new AppearanceSettings('system', {})

  /** The size in points: the user's, or `platformDefault`. */
  size(kind: TextKind, platformDefault = defaultTextSizes[kind]): number {
    return this.sizes[kind] ?? platformDefault
  }

  isCustom(kind: TextKind): boolean {
    return this.sizes[kind] !== undefined
  }

  withMode(mode: AppearanceMode): AppearanceSettings {
    return new AppearanceSettings(mode, this.sizes)
  }

  /** Clamped to the range and rounded to the point; the platform default forgets the size. */
  withSize(kind: TextKind, size: number, platformDefault = defaultTextSizes[kind]): AppearanceSettings {
    if (!Number.isFinite(size)) return this
    const clamped = Math.min(Math.max(Math.round(size), textSizeRange.lower), textSizeRange.upper)
    const sizes = { ...this.sizes }
    if (clamped === platformDefault) delete sizes[kind]
    else sizes[kind] = clamped
    return new AppearanceSettings(this.mode, sizes)
  }

  /** Everything back to the defaults. */
  reset(): AppearanceSettings {
    return AppearanceSettings.default
  }

  get isDefault(): boolean {
    return this.mode === 'system' && textKinds.every((kind) => !this.isCustom(kind))
  }

  equals(other: AppearanceSettings): boolean {
    return this.mode === other.mode && textKinds.every((kind) => this.sizes[kind] === other.sizes[kind])
  }

  toJSON(): AppearanceSettingsJSON {
    const sizes: AppearanceSettingsJSON['sizes'] = {}
    for (const kind of textKinds) {
      const size = this.sizes[kind]
      if (size !== undefined) sizes[kind] = size
    }
    return { theme: this.mode, sizes }
  }

  /** Saved by another version: an unknown look is the system's, unknown kinds and out-of-range sizes are dropped. */
  static fromJSON(json: unknown): AppearanceSettings {
    const object = json && typeof json === 'object' ? (json as Record<string, unknown>) : {}
    const mode = appearanceModes.find((each) => each === object.theme) ?? 'system'
    const raw = object.sizes && typeof object.sizes === 'object' ? (object.sizes as Record<string, unknown>) : {}
    const sizes: Partial<Record<TextKind, number>> = {}
    for (const [key, value] of Object.entries(raw)) {
      const kind = textKinds.find((each) => each === key)
      if (kind && typeof value === 'number' && value >= textSizeRange.lower && value <= textSizeRange.upper) sizes[kind] = value
    }
    return new AppearanceSettings(mode, sizes)
  }
}
