import { GatewayClientError } from '../client.ts'
import { describeError } from '../describe.ts'
import { Observable } from '../observable.ts'
import { SendCancelledError, type ChatSession } from '../session/chat-session.ts'
import { ComposerModels } from './model/composer-models.ts'
import { ReasoningEffort } from './model/reasoning-effort.ts'
import { ComposerSlash } from './slash/composer-slash.ts'
import { isLinkFailure, runSlash, type SlashOutcome } from './slash/run-slash.ts'
import { isSlashCommand, parseSlashCommand } from './slash/slash-commands.ts'

export interface ComposerView {
  draft: string
  /** The prompt is being submitted. */
  isSubmitting: boolean
  /** A composer failure; a failed `prompt.submit` shows in the transcript instead. */
  error?: string
  /** A `/compress` (or a Bot Chat's `/new`) is running; the composer stays usable (package F shows its card). */
  isCompressing: boolean
}

/** What the composer's client-side slash actions need from the chat list (`ChatManager`). */
export interface ComposerActions {
  /** `/new`: a new chat on the chat's profile. */
  newChat(chat: ChatSession): Promise<unknown>
  /** `/resume <id>`: opens a stored session of the chat's profile. */
  openStored(chat: ChatSession, storedID: string): Promise<unknown>
}

/**
 * One chat's composer state (HermesKit's `ChatComposer`, the parts package A needs):
 * the draft lives with the chat, not with its view, so nothing typed is lost when another
 * chat is shown, and a chat shown again comes back with its draft. Attachments (E),
 * model and effort (D) and held prompts (F) extend it.
 */
export class ChatComposer extends Observable<ComposerView> {
  private sending?: { cancelled: boolean }
  /** `error`, when a lost connection caused it: a reconnect clears it. */
  private linkError?: string
  /** The model and reasoning-effort pickers (package D). */
  readonly models: ComposerModels
  /** The slash-command list (package D). */
  readonly slash: ComposerSlash

  constructor(readonly session: ChatSession, private readonly actions?: ComposerActions) {
    super({ draft: '', isSubmitting: false, isCompressing: false })
    const errors = { showError: (message: string, cause?: unknown) => this.showError(message, cause), clearError: () => this.clearError() }
    this.models = new ComposerModels(session, errors)
    this.slash = new ComposerSlash(session, this)
  }

  /**
   * Loads the slash catalog and the model options side by side: when the chat shows and
   * again after a reconnect (the runtime id may have changed). An error a lost connection
   * caused goes then.
   */
  async loadCommandsAndOptions(): Promise<void> {
    const error = this.get().error
    if (error !== undefined && (error === this.linkError || this.models.isOptionsError(error))) this.clearError()
    await Promise.all([this.slash.loadCatalog().catch(() => {}), this.models.loadOptions()])
  }

  /** Shows `message` in the composer's error row, remembering whether a reconnect should clear it. */
  showError(message: string, cause?: unknown): void {
    this.linkError = cause !== undefined && isLinkFailure(cause) ? message : undefined
    this.set({ ...this.get(), error: message })
  }

  get draft(): string {
    return this.get().draft
  }

  setDraft(draft: string): void {
    if (draft === this.get().draft) return
    this.set({ ...this.get(), draft })
    this.slash.draftChanged()
  }

  /** Something to send, and no send in flight. */
  get canSubmit(): boolean {
    return !this.get().isSubmitting && this.get().draft.trim() !== ''
  }

  /**
   * Sends the draft. The draft clears at once (the prompt's bubble shows it). A send
   * cancelled or refused before it went out puts the text back; a failed `prompt.submit`
   * keeps its bubble, marked, in the transcript.
   */
  async submit(): Promise<void> {
    if (!this.canSubmit) return
    if (isSlashCommand(this.get().draft)) {
      await this.submitSlash()
      return
    }
    this.slash.resetSuppression()
    const text = this.get().draft
    const signal = { cancelled: false }
    this.sending = signal
    this.set({ ...this.get(), draft: '', isSubmitting: true })
    try {
      await this.session.send(text, signal)
    } catch (error) {
      if (error instanceof SendCancelledError) {
        this.restoreText(text)
      } else if (error instanceof GatewayClientError && error.kind === 'notConnected') {
        // Offline before it went out: the bubble went, the text comes back here.
        this.restoreText(text)
        this.set({ ...this.get(), error: describeError(error) })
      }
    } finally {
      if (this.sending === signal) this.sending = undefined
      this.set({ ...this.get(), isSubmitting: false })
    }
  }

  /** Stops a send that is still waiting to go out; its text comes back. */
  cancelSubmit(): void {
    if (this.sending) this.sending.cancelled = true
  }

  clearError(): void {
    this.linkError = undefined
    if (this.get().error === undefined) return
    const { error: _, ...rest } = this.get()
    this.set(rest)
  }

  // MARK: Slash commands (package D)

  /**
   * Runs the draft as a slash command; the outcome shows in the transcript. Client
   * actions (`/new`, `/model`, …) run here too. The draft clears at once, and what is
   * typed meanwhile stays. A slow command (`/compress`, a skill) does not hold up the
   * composer: as on Desktop, the next message or command goes out while it runs. A second
   * compaction while one runs is dropped (Desktop: `use-prompt-actions/slash.ts:696-709`).
   */
  async submitSlash(): Promise<SlashOutcome | undefined> {
    const text = this.get().draft
    if (this.get().isSubmitting || !isSlashCommand(text)) return undefined
    this.slash.close()
    this.slash.resetSuppression()
    const compresses = this.compacts(parseSlashCommand(text).name)
    if (compresses && this.get().isCompressing) {
      this.set({ ...this.get(), draft: '' })
      return { kind: 'handled' }
    }
    this.set({ ...this.get(), draft: '', ...(compresses ? { isCompressing: true } : {}) })
    try {
      const slash = this.slash
      const outcome = await runSlash(this.session, text, {
        get catalog() { return slash.catalog },
        load: () => slash.requireCatalog(),
      })
      switch (outcome.kind) {
        case 'unavailable': this.session.appendLocalNote(outcome.reason); break
        case 'prefill': this.restoreText(outcome.text); break
        case 'clientAction': await this.runClientAction(outcome.name, outcome.argument); break
        default: break
      }
      return outcome
    } catch (error) {
      // The command comes back only into an empty draft: in front of what was typed since,
      // the next Return would run it with that prose as its argument.
      if (this.get().draft.trim() === '') this.set({ ...this.get(), draft: text })
      this.session.appendLocalNote(`/${parseSlashCommand(text).name}: ${describeError(error)}`)
      return { kind: 'unavailable', reason: describeError(error) }
    } finally {
      if (compresses) this.set({ ...this.get(), isCompressing: false })
    }
  }

  /**
   * Whether `/name` runs a compaction: `/compress` or an alias, and in a Bot Chat `/new`,
   * `/reset` and `/clear`, which compact instead (`plugins/hermes-bots/plugin.tsx:771-797`).
   */
  private compacts(name: string): boolean {
    const canonical = this.slash.catalog?.canonicalName(name).slice(1) ?? name
    const names = this.session.kind === 'botChat' ? ['compress', 'compact', 'new', 'reset', 'clear'] : ['compress', 'compact']
    return names.includes(name) || names.includes(canonical)
  }

  /**
   * Desktop's client-side actions (`use-prompt-actions/slash.ts:518-1135`) that this app
   * has a feature for; the rest get a local note. Nothing is sent as a prompt.
   */
  async runClientAction(name: string, argument: string): Promise<void> {
    const note = (text: string) => this.session.appendLocalNote(text)
    try {
      switch (name) {
        case 'new': case 'reset': case 'clear':
          // A Bot Chat never gets here: `runSlash` compacts it instead.
          if (!this.actions) throw new GatewayClientError('notConnected')
          await this.actions.newChat(this.session)
          return
        case 'help': case 'commands':
          note((await this.slash.requireCatalog()).helpText)
          return
        case 'model': {
          if (argument === '') {
            this.models.requestPicker(true)
            return
          }
          const provider = this.models.get().catalog?.providers.find((row) => row.models.includes(argument))
          if (provider) await this.models.selectModel({ provider: provider.slug, model: argument })
          else note(`Model ${argument} is not available in this chat.`)
          return
        }
        case 'profile':
          note('/profile is not available in this app yet. Choose a bot in the sidebar; new chats cannot change profile here.')
          return
        case 'reasoning':
          if (argument === '') note(`Reasoning effort: ${ReasoningEffort.label(this.models.currentEffort)}`)
          else if (this.models.effortChoices.includes(argument)) await this.models.selectEffort(argument)
          else note(`Reasoning option ${argument} is not available in this chat.`)
          return
        case 'resume': case 'sessions': case 'switch':
          if (argument !== '' && this.actions) await this.actions.openStored(this.session, argument)
          else note('Choose a chat from History. This app cannot search sessions by slash command yet.')
          return
        default:
          note(`/${name} is not available in this app yet.`)
      }
    } catch (error) {
      note(`/${name}: ${describeError(error)}`)
    }
  }

  /**
   * Puts a failed send's text back, keeping what was typed meanwhile: the earlier text
   * first, then what is typed now; nothing is overwritten.
   */
  restoreText(text: string): void {
    const draft = this.get().draft
    if (draft.trim() === '') this.set({ ...this.get(), draft: text })
    else if (text.trim() !== '') this.set({ ...this.get(), draft: text + '\n' + draft })
  }
}
