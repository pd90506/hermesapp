import { GatewayClientError } from '../client.ts'
import { describeError } from '../describe.ts'
import { Observable } from '../observable.ts'
import { SendCancelledError, type ChatSession } from '../session/chat-session.ts'
import { PromptQueue, compressCommand } from './queue/prompt-queue.ts'

export interface ComposerView {
  draft: string
  /** The prompt is being submitted. */
  isSubmitting: boolean
  /** A composer failure; a failed `prompt.submit` shows in the transcript instead. */
  error?: string
}

/**
 * One chat's composer state (HermesKit's `ChatComposer`, the parts package A needs):
 * the draft lives with the chat, not with its view, so nothing typed is lost when another
 * chat is shown, and a chat shown again comes back with its draft. Attachments (E),
 * model and effort (D) and held prompts (F) extend it.
 */
export class ChatComposer extends Observable<ComposerView> {
  private sending?: { cancelled: boolean }
  /** Messages held while a reply or a compression runs, and `/compress` (package F). */
  readonly queue: PromptQueue

  constructor(readonly session: ChatSession) {
    super({ draft: '', isSubmitting: false })
    this.queue = new PromptQueue(this, session)
  }

  get draft(): string {
    return this.get().draft
  }

  setDraft(draft: string): void {
    if (draft === this.get().draft) return
    this.set({ ...this.get(), draft })
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
    const text = this.get().draft
    // Package F: `/compress` runs here until D routes slash commands; text sent while a
    // reply or a compression runs waits in the app (`PromptQueue`).
    const compress = compressCommand(text)
    if (compress) {
      this.clearDraftAndError()
      await this.queue.compress(compress.topic)
      return
    }
    if (this.queue.holdsNextSend) {
      this.queue.hold(text)
      this.clearDraftAndError()
      return
    }
    const signal = { cancelled: false }
    this.sending = signal
    this.set({ draft: '', isSubmitting: true })
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

  private clearDraftAndError(): void {
    const { error: _, ...rest } = this.get()
    this.set({ ...rest, draft: '' })
  }

  /** Shows a composer message (a held message's Cancel or Steer could not run). */
  showError(message: string): void {
    this.set({ ...this.get(), error: message })
  }

  clearError(): void {
    if (this.get().error === undefined) return
    const { error: _, ...rest } = this.get()
    this.set(rest)
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
