import { describeError } from '../../describe.ts'
import { Observable } from '../../observable.ts'
import type { JSONValue } from '../../protocol/jsonrpc.ts'
import type { ChatSession } from '../../session/chat-session.ts'
import { ModelCatalog, modelDisplayName, sessionModelValue, type ModelChoice } from './model-catalog.ts'
import { ReasoningEffort } from './reasoning-effort.ts'

/** A model switch the gateway holds back until the user confirms it (`confirm_required`, e.g. an expensive model). */
export interface PendingModelSwitch {
  choice: ModelChoice
  message: string
}

export interface ComposerModelsView {
  /** `undefined` until `model.options` answered. */
  catalog?: ModelCatalog
  /** Reload Models is reading the catalog again. */
  isReloading: boolean
  pendingSwitch?: PendingModelSwitch
  /** The effort `config.get` reported, for a session whose `session.info` lacks it. */
  fetchedEffort?: string
  /** `/model` without a model: the view opens its model picker (Desktop's `slash.ts:1284-1295`). */
  isPickerRequested: boolean
}

/** Where the model controls report a failure: the composer's error row. */
export interface ComposerErrorSink {
  showError(message: string, cause?: unknown): void
  clearError(): void
}

const record = (value: unknown): Record<string, JSONValue> | undefined =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, JSONValue> : undefined
const nonEmpty = (value: unknown): string | undefined =>
  typeof value === 'string' && value.trim() !== '' ? value : undefined

/**
 * One chat's model and reasoning-effort pickers (the model half of HermesKit's
 * `ChatComposer`): the catalog from `model.options`, the session's current pair from
 * `session.info`, switches with `config.set` for this session only (`--session`), and
 * the expensive-model confirmation.
 */
export class ComposerModels extends Observable<ComposerModelsView> {
  /** Bumped per pick; an answer for an older pick changes nothing on screen. */
  private modelPick = 0
  private optionsError?: string
  private switchGeneration = 0
  private appliedSwitchGeneration = 0

  constructor(private readonly session: ChatSession, private readonly errors: ComposerErrorSink) {
    super({ isReloading: false, isPickerRequested: false })
  }

  private update(change: Partial<ComposerModelsView>): void {
    const next: ComposerModelsView = { ...this.get(), ...change }
    for (const key of Object.keys(next) as Array<keyof ComposerModelsView>) if (next[key] === undefined) delete next[key]
    this.set(next)
  }

  /** The session's model: `session.info` first, then the catalog's answer. */
  get currentModel(): string | undefined {
    return nonEmpty(this.session.get().info?.model) ?? this.get().catalog?.model
  }

  get currentProvider(): string | undefined {
    return nonEmpty(this.session.get().info?.provider) ?? this.get().catalog?.provider
  }

  get currentModelLabel(): string | undefined {
    const model = this.currentModel
    return model === undefined ? undefined : modelDisplayName(model)
  }

  isCurrent(choice: ModelChoice): boolean {
    if (choice.model !== this.currentModel) return false
    const provider = this.currentProvider
    return provider === undefined || choice.provider.toLowerCase() === provider.toLowerCase()
  }

  /** Effort levels for the current model; empty (picker hidden) until the catalog loads, or when the model has no reasoning control. */
  get effortChoices(): string[] {
    const { catalog } = this.get()
    const model = this.currentModel
    if (!catalog || model === undefined) return []
    return ReasoningEffort.choices(catalog.capabilities(model, this.currentProvider))
  }

  /** The session's effort; Hermes' default when nothing is reported. */
  get currentEffort(): string {
    return ReasoningEffort.normalized(this.session.get().info?.reasoning_effort) ?? this.get().fetchedEffort ??
      ReasoningEffort.defaultLevel
  }

  private params(extra: Record<string, JSONValue> = {}): Record<string, JSONValue> {
    const params: Record<string, JSONValue> = { ...extra }
    if (this.session.profile !== undefined) params.profile = this.session.profile
    return params
  }

  private async fetchEffort(): Promise<string | undefined> {
    if (this.session.isRuntimeGone) return ReasoningEffort.normalized(this.session.info?.reasoning_effort)
    const client = await this.session.liveClient()
    const answer = record(await client.call('config.get', this.params({ key: 'reasoning', session_id: this.session.sessionID })))
    return ReasoningEffort.normalized(typeof answer?.value === 'string' ? answer.value : undefined)
  }

  /**
   * Loads the model catalog and, when `session.info` lacks it, the effort. `refresh`
   * (Reload Models) has the backend re-read each provider's live list instead of its
   * hour-long cache, as Desktop's Refresh Models (`model-menu-panel.tsx`).
   */
  async loadOptions(refresh = false): Promise<void> {
    if (refresh) this.update({ isReloading: true })
    try {
      const client = await this.session.liveClient()
      const params = this.params({ explicit_only: true })
      // The profile's catalog while a reclaimed runtime waits to be resumed.
      if (!this.session.isRuntimeGone) params.session_id = this.session.sessionID
      if (refresh) params.refresh = true
      const catalog = new ModelCatalog(await client.call('model.options', params))
      this.update({ catalog })
      if (ReasoningEffort.normalized(this.session.get().info?.reasoning_effort) === undefined) {
        this.update({ fetchedEffort: await this.fetchEffort() })
      }
      this.optionsError = undefined
    } catch (error) {
      const message = `Couldn't load models: ${describeError(error)}`
      this.errors.showError(message, error)
      this.optionsError = message
    } finally {
      if (refresh) this.update({ isReloading: false })
    }
  }

  /** Whether the last `loadOptions` failed with this message (a reconnect clears it). */
  isOptionsError(message: string | undefined): boolean {
    return message !== undefined && message === this.optionsError
  }

  /** Switches this session's model. A `confirm_required` answer becomes `pendingSwitch` for the view to ask about. */
  async selectModel(choice: ModelChoice): Promise<void> {
    if (this.isCurrent(choice)) return
    await this.switchModel(choice, false)
  }

  async confirmPendingSwitch(): Promise<void> {
    const pending = this.get().pendingSwitch
    if (!pending) return
    this.update({ pendingSwitch: undefined })
    await this.switchModel(pending.choice, true)
  }

  cancelPendingSwitch(): void {
    this.update({ pendingSwitch: undefined })
  }

  requestPicker(open: boolean): void {
    if (this.get().isPickerRequested !== open) this.update({ isPickerRequested: open })
  }

  private async switchModel(choice: ModelChoice, confirmed: boolean): Promise<void> {
    this.errors.clearError()
    this.modelPick += 1
    const pick = this.modelPick
    this.switchGeneration += 1
    const generation = this.switchGeneration
    try {
      const client = await this.session.liveClient()
      const params = this.params({ key: 'model', value: sessionModelValue(choice), session_id: this.session.sessionID })
      if (confirmed) params.confirm_expensive_model = true
      const result = record(await client.call('config.set', params)) ?? {}
      const confirmRequired = result.confirm_required === true
      // Show the newest switch that was *applied*. The gateway applies them in arrival
      // order, so a success newer than the last one shown is what the session runs.
      if (!confirmRequired && generation > this.appliedSwitchGeneration) {
        this.appliedSwitchGeneration = generation
        // `session.info` follows when the agent is built; a lazy session or a deferred
        // (mid-turn) switch sends none until later, so show the pick now.
        this.session.showInfo({ model: choice.model, provider: choice.provider })
      }
      if (pick !== this.modelPick) return
      if (confirmRequired) {
        if (confirmed) {
          // Asked twice: Desktop treats that as a failure rather than loop (`guarded-model-switch.ts:44-50`).
          this.errors.showError(`Hermes did not switch to ${modelDisplayName(choice.model)}.`)
        } else {
          const message = nonEmpty(result.confirm_message) ?? nonEmpty(result.warning) ??
            `Switch this chat to ${modelDisplayName(choice.model)}?`
          this.update({ pendingSwitch: { choice, message } })
        }
        return
      }
      // The effort a new model starts with may differ; read it again.
      try {
        this.update({ fetchedEffort: await this.fetchEffort() })
      } catch { /* keep the last one */ }
    } catch (error) {
      if (pick !== this.modelPick) return
      this.errors.showError(`Couldn't switch the model: ${describeError(error)}`, error)
    }
  }

  /**
   * Sets this session's reasoning effort (`none` turns thinking off). Only `none` and the
   * levels are sent: other words reach `config.set reasoning`'s display branch, which
   * rewrites the profile's display config (`methods_config_set.py:312-317`).
   */
  async selectEffort(effort: string): Promise<void> {
    if (effort === this.currentEffort) return
    this.errors.clearError()
    if (!ReasoningEffort.isSendable(effort)) {
      this.errors.showError(`${effort} is not a reasoning effort Hermes accepts.`)
      return
    }
    try {
      const client = await this.session.liveClient()
      const result = record(await client.call('config.set', this.params({ key: 'reasoning', value: effort, session_id: this.session.sessionID })))
      this.session.showInfo({ reasoning_effort: typeof result?.value === 'string' ? result.value : effort })
    } catch (error) {
      this.errors.showError(`Couldn't change the reasoning effort: ${describeError(error)}`, error)
    }
  }
}
