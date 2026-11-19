import {
  AppearanceSettings, MarkdownColors, Observable, defaultTextSizes, textKinds,
  type AppearanceMode, type ColorTheme, type TextKind,
} from '@talaria/hermes-core'
import type { SavedSettings, TalariaBridge } from '../../../../shared/bridge.ts'

export interface AppearanceSnapshot {
  settings: AppearanceSettings
  /** The colour theme is its preset (HermesKit keeps the theme with the Markdown colours). */
  colors: MarkdownColors
}

/**
 * Settings ▸ Appearance, as the Mac's `AppModel.appearance` and `markdownColors`: kept in
 * settings.json in HermesKit's shapes, and applied to the window's document as
 * `data-theme` and the text size variables (theme/tokens.css, theme/themes/themes.css).
 * Light or dark goes to the main process (`nativeTheme.themeSource`). The settings
 * window is a portal of this document, so it follows without its own copy.
 */
export class AppearanceStore extends Observable<AppearanceSnapshot> {
  constructor(
    private readonly bridge: Pick<TalariaBridge, 'theme'>,
    private readonly save: (change: Partial<SavedSettings>) => Promise<void>,
    private readonly root: () => HTMLElement | null = () => document.documentElement,
  ) {
    super({ settings: AppearanceSettings.default, colors: MarkdownColors.default })
  }

  /** The saved settings, applied before the window draws. */
  restore(saved: SavedSettings): void {
    this.set({
      settings: AppearanceSettings.fromJSON(saved.appearance),
      colors: MarkdownColors.fromJSON(saved.markdownColors),
    })
    this.apply()
  }

  setMode(mode: AppearanceMode): void {
    this.change({ settings: this.get().settings.withMode(mode) })
  }

  /** Choosing a theme forgets the Markdown colours the user changed (`MarkdownColors.choose`). */
  setTheme(theme: ColorTheme): void {
    this.change({ colors: this.get().colors.choose(theme) })
  }

  setSize(kind: TextKind, size: number): void {
    this.change({ settings: this.get().settings.withSize(kind, size) })
  }

  /** Restore Defaults: the look and the sizes; the theme stays, as on the Mac. */
  restoreDefaults(): void {
    this.change({ settings: this.get().settings.reset() })
  }

  private change(change: Partial<AppearanceSnapshot>): void {
    const before = this.get()
    const next = { ...before, ...change }
    if (next.settings.equals(before.settings) && next.colors.equals(before.colors)) return
    this.set(next)
    this.apply()
    void this.save({ appearance: next.settings.toJSON(), markdownColors: next.colors.toJSON() }).catch(() => {})
  }

  private apply(): void {
    const { settings, colors } = this.get()
    this.bridge.theme.setMode(settings.mode)
    const root = this.root()
    if (!root) return
    root.dataset.theme = colors.preset
    const variables: Record<TextKind, string> = { ui: '--text-ui', content: '--text-content-size', code: '--text-code-size' }
    for (const kind of textKinds) {
      if (settings.isCustom(kind)) root.style.setProperty(variables[kind], String(settings.size(kind, defaultTextSizes[kind])))
      else root.style.removeProperty(variables[kind])
    }
  }
}
