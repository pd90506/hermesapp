import { GatewayClientError } from '../../client.ts'
import { describeError } from '../../describe.ts'
import { Observable } from '../../observable.ts'
import { SendCancelledError, type ChatSession } from '../../session/chat-session.ts'

/** A message sent while a reply or a compression runs, waiting here, not in Hermes's queue. */
export interface HeldPrompt {
  readonly id: string
  readonly text: string
}

export interface PromptQueueView {
  /** Held messages, oldest first. */
  held: readonly HeldPrompt[]
  /** A compression this composer asked for is running (`compress`). */
  isCompressing: boolean
}

/** What the queue needs from its composer (`ChatComposer`). */
export interface QueueComposer {
  readonly draft: string
  setDraft(draft: string): void
  showError(message: string): void
}

/** Shown when Cancel finds text in the composer (the Mac's "Save Your Draft First"). */
export const heldCancelBlockedMessage =
  'The message box already has text. Send, copy or clear it, then cancel the queued message again.'

/**
 * `/compress` or `/compact` with an optional focus topic, or undefined for any other text.
 * Until package D's slash commands route them, the composer runs these itself.
 */
export function compressCommand(text: string): { topic?: string } | undefined {
  const match = /^\/(compress|compact)(?:\s+([\s\S]*))?$/.exec(text.trim())
  if (!match) return undefined
  const topic = match[2]?.trim()
  return topic ? { topic } : {}
}

let heldCounter = 0

/**
 * The chat's local queue (HermesKit's `ChatComposer.heldPrompts`, PR #145): a text message
 * sent while a reply or a compression runs waits here, above the composer, until the
 * session is free, then goes out one at a time. Each can be taken back into an empty
 * composer (`cancel`) or handed to the running reply (`steer`). Hermes's own queue can't
 * give one back (no RPC removes a queued prompt; only Stop clears them all,
 * `tui_gateway/session_auto_continue.py:147-176`), which is why Desktop keeps a remote
 * dashboard's queue in the client too (`store/composer-queue.ts:13-28`). Kept on this
 * device only, in memory, like Desktop's.
 *
 * It also tracks a compression this composer started (`compress`), which with Hermes's
 * own compactions (`ChatView.isCompacting`) is the "Compressing context…" card.
 */
export class PromptQueue extends Observable<PromptQueueView> {
  private isSendingHeld = false
  private lastKey?: string

  constructor(private readonly composer: QueueComposer, readonly session: ChatSession) {
    super({ held: [], isCompressing: false })
    // A held message goes out once the session is free (the Mac view's `.task(id:)`).
    session.subscribe(() => this.poke())
  }

  get held(): readonly HeldPrompt[] {
    return this.get().held
  }

  /** The "Compressing context…" card: a `/compress` sent here, or any compaction Hermes reports. */
  get showsCompressing(): boolean {
    return this.get().isCompressing || this.session.get().isCompacting
  }

  /** No reply, compression or prompt queued in Hermes ahead of a held one. */
  get isSessionFree(): boolean {
    const chat = this.session.get()
    return !chat.isRunning && !this.showsCompressing && chat.queuedPrompts.length === 0 && !this.isSendingHeld
  }

  /** Whether a send now waits here: while a reply or a compression runs, or behind messages already held. */
  get holdsNextSend(): boolean {
    return !this.isSessionFree || this.get().held.length > 0
  }

  /**
   * Whether a held message can go to the running reply as a steer: only while a reply
   * runs. During a compression alone Hermes would queue it, out of reach again.
   */
  get canSteer(): boolean {
    return this.session.get().isRunning && !this.showsCompressing
  }

  /** Holds `text` at the end of the queue. */
  hold(text: string): void {
    if (text.trim() === '') return
    heldCounter += 1
    this.setHeld([...this.get().held, { id: `held-${heldCounter}`, text }])
  }

  /**
   * Sends the oldest held message if the session is free. The next waits for the turn
   * this one starts. One that never reached Hermes comes back to the front; a failed
   * `prompt.submit` shows in the chat, as any failed send.
   */
  async sendNext(): Promise<void> {
    const next = this.get().held[0]
    if (!next || !this.isSessionFree) return
    this.isSendingHeld = true
    this.setHeld(this.get().held.slice(1))
    let returned = false
    try {
      await this.session.send(next.text)
    } catch (error) {
      if (error instanceof SendCancelledError || (error instanceof GatewayClientError && error.kind === 'notConnected')) {
        returned = true
        this.setHeld([next, ...this.get().held])
      }
    } finally {
      this.isSendingHeld = false
    }
    // Sent: the next waits for its turn. Returned (offline): a reconnect retries (`retry`).
    if (!returned) this.poke()
  }

  /** Tries the queue again, e.g. once the connection is back. */
  retry(): void {
    this.lastKey = undefined
    this.poke()
  }

  /**
   * Takes a held message back into the composer. Only into an empty draft: with text
   * there it stays held, the composer says why, and false is returned, so nothing typed
   * is lost or mixed up.
   */
  cancel(id: string): boolean {
    const prompt = this.get().held.find((held) => held.id === id)
    if (!prompt) return true
    if (this.composer.draft.trim() !== '') {
      this.composer.showError(heldCancelBlockedMessage)
      return false
    }
    this.setHeld(this.get().held.filter((held) => held.id !== id))
    this.composer.setDraft(prompt.text)
    return true
  }

  /**
   * Hands a held message to the running reply (`ChatSession.steer`): the agent sees it
   * with its next tool result. If the turn ended meanwhile, Hermes answers `rejected` and
   * it goes as a normal prompt. A failed call keeps it held, in its place.
   */
  async steer(id: string): Promise<void> {
    const held = this.get().held
    const index = held.findIndex((prompt) => prompt.id === id)
    if (index < 0) return
    const prompt = held[index]!
    this.setHeld(held.filter((other) => other.id !== id))
    try {
      await this.session.steer(prompt.text)
    } catch (error) {
      const now = [...this.get().held]
      now.splice(Math.min(index, now.length), 0, prompt)
      this.setHeld(now)
      this.composer.showError(describeError(error))
    }
  }

  /**
   * Runs a compression (`ChatSession.compress`). The composer stays usable meanwhile;
   * what is sent then waits here. A second one while it runs is dropped, as on Desktop
   * (`use-prompt-actions/slash.ts:696-709`). A failure goes in the chat as a note.
   */
  async compress(topic?: string): Promise<void> {
    if (this.get().isCompressing) return
    this.set({ ...this.get(), isCompressing: true })
    this.poke()
    try {
      await this.session.compress(topic)
    } catch (error) {
      this.session.appendLocalNote(`/compress: ${describeError(error)}`)
    } finally {
      this.set({ ...this.get(), isCompressing: false })
      this.poke()
    }
  }

  private setHeld(held: readonly HeldPrompt[]): void {
    this.set({ ...this.get(), held })
  }

  /** Sends the next held message when what it waits on changed. */
  private poke(): void {
    const chat = this.session.get()
    const key = [chat.isRunning, this.showsCompressing, chat.queuedPrompts.length, this.get().held.length].join()
    if (key === this.lastKey) return
    this.lastKey = key
    if (this.get().held.length > 0) void this.sendNext()
  }
}
