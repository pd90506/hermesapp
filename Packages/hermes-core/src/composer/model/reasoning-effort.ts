import type { ModelCapabilities } from './model-catalog.ts'

/**
 * Hermes' reasoning-effort words (HermesKit's `ReasoningEffort`), mirroring
 * `apps/shared/src/reasoning-effort.ts`, itself a mirror of the backend's
 * `VALID_REASONING_EFFORTS`.
 */
export const ReasoningEffort = {
  /** The levels, ascending. `none` is not a level: it is thinking turned off. */
  levels: ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'] as readonly string[],
  off: 'none',
  /** What Hermes uses when nothing is configured (`reasoning-effort.ts:13-15`). */
  defaultLevel: 'medium',

  /**
   * The choices to offer for a model, in menu order. Empty when the model has no
   * reasoning control, so the picker hides (`reasoning-pill.tsx:43-45`). `none` comes
   * first unless the model cannot turn thinking off. An unknown model keeps the dial:
   * the catalog itself defaults `reasoning` to true (`inventory.py:317-321`).
   */
  choices(capabilities: ModelCapabilities | undefined): string[] {
    if (capabilities?.reasoning === false) return []
    const canDisable = capabilities?.canDisableReasoning !== false
    return [...(canDisable ? [ReasoningEffort.off] : []), ...ReasoningEffort.levels]
  },

  /**
   * Whether `config.set reasoning` may be sent this value: `none` or a level, exactly as
   * written. Display words (`on`, `off`, `show`, …) would rewrite the profile's display
   * config instead (`methods_config_set.py:312-317`).
   */
  isSendable(value: string): boolean {
    return value === ReasoningEffort.off || ReasoningEffort.levels.includes(value)
  },

  /** Normalises a reported value (`" High "` → `high`); `undefined` for blanks. */
  normalized(value: string | null | undefined): string | undefined {
    const trimmed = value?.trim().toLowerCase()
    return trimmed ? trimmed : undefined
  },

  /** Menu and pill copy, from Desktop's `i18n/en.ts` `modelOptions`. */
  label(value: string): string {
    switch (value.toLowerCase()) {
      case 'none': return 'Off'
      case 'minimal': return 'Minimal'
      case 'low': return 'Low'
      case 'medium': return 'Medium'
      case 'high': return 'High'
      case 'xhigh': return 'Extra High'
      case 'max': return 'Max'
      case 'ultra': return 'Ultra'
      default: return value
    }
  },
}
