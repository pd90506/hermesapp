import { GatewayClientError } from '../client.ts'
import { describeError } from '../describe.ts'
import { Observable } from '../observable.ts'
import { SendCancelledError, type ChatSession } from '../session/chat-session.ts'
import { AttachmentError } from './attachments/policy.ts'
import { StrandedImages } from './attachments/stranded.ts'
import { AttachmentTray } from './attachments/tray.ts'

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
  /** E: the images and files attached to this chat's composer. */
  readonly attachments: AttachmentTray

  constructor(readonly session: ChatSession, stranded = new StrandedImages()) {
    super({ draft: '', isSubmitting: false })
    this.attachments = new AttachmentTray(session, stranded, (message) => {
      if (message === undefined) this.clearError()
      else this.set({ ...this.get(), error: message })
    })
    // Send's state follows the cards (uploads under way, cards added or removed).
    this.attachments.subscribe(() => this.set({ ...this.get() }))
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
    if (this.get().isSubmitting || this.attachments.isUploading) return false
    return this.get().draft.trim() !== '' || this.attachments.hasCards
  }

  /**
   * Sends the draft. The draft clears at once (the prompt's bubble shows it). A send
   * cancelled or refused before it went out puts the text back; a failed `prompt.submit`
   * keeps its bubble, marked, in the transcript.
   */
  async submit(): Promise<void> {
    // Images still uploading are waited for (the Send button waits for them too).
    if (this.attachments.hasCards && !this.get().isSubmitting && !this.attachments.isUploadingFiles) {
      return this.submitWithAttachments()
    }
    if (!this.canSubmit) return
    const text = this.get().draft
    const signal = { cancelled: false }
    this.sending = signal
    this.set({ draft: '', isSubmitting: true })
    try {
      await this.session.send(text, signal)
    } catch (error) {
      if (error instanceof SendCancelledError) {
        this.restoreText(text)
      } else if (error instanceof AttachmentError || (error instanceof GatewayClientError && error.kind === 'notConnected')) {
        // Offline before it went out: the bubble went, the text comes back here.
        this.restoreText(text)
        this.set({ ...this.get(), error: describeError(error) })
      }
    } finally {
      if (this.sending === signal) this.sending = undefined
      this.set({ ...this.get(), isSubmitting: false })
    }
  }

  /**
   * E: sends the draft with the attached images and files (HermesKit's `ChatComposer.submit`).
   * The draft and the cards clear at once (the bubble shows them). If the send fails, the
   * images it queued come off the queue, and the cards and the draft come back for a
   * retry, which uploads them again.
   */
  private async submitWithAttachments(): Promise<void> {
    const text = this.get().draft
    const signal = { cancelled: false }
    this.sending = signal
    this.set({ draft: '', isSubmitting: true })
    const tray = this.attachments
    tray.isSending = true
    try {
      await tray.uploadsSettled()
      const taken = tray.take()
      const prompt = tray.promptFor(text, taken)
      try {
        await this.session.send(text, signal, prompt)
      } catch (error) {
        await prompt.release()
        tray.isSending = false
        this.restoreText(text)
        tray.restore(taken)
        if (error instanceof AttachmentError || (error instanceof GatewayClientError && error.kind === 'notConnected')) {
          this.set({ ...this.get(), error: error instanceof AttachmentError ? error.message : describeError(error) })
        }
      }
    } finally {
      tray.isSending = false
      if (this.sending === signal) this.sending = undefined
      this.set({ ...this.get(), isSubmitting: false })
    }
  }

  /** Stops a send that is still waiting to go out; its text comes back. */
  cancelSubmit(): void {
    if (this.sending) this.sending.cancelled = true
  }

  /** E: shows a failure in the composer (an attachment that could not be read or added). */
  reportError(message: string): void {
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
