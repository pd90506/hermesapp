import { describeError } from '../../describe.ts'
import { Observable } from '../../observable.ts'
import type { ChatSession } from '../../session/chat-session.ts'
import {
  SlashCatalog, SlashCompletions, implicitAcceptIndex, isSlashCompletionCandidate, slashRows,
  type SlashRow, type SlashSuggestion,
} from './slash-commands.ts'

/** The keys the slash list takes: arrows, Tab, plain Return, Esc (HermesKit's `SlashListKey`). */
export type SlashListKey = 'up' | 'down' | 'tab' | 'accept' | 'escape'

export interface ComposerSlashView {
  suggestions: readonly SlashSuggestion[]
  selection: number
  isOpen: boolean
  /** No rows: Desktop's "No matches." or why the lookup failed. */
  notice?: string
}

/** The draft the list reads and writes (the composer). */
export interface SlashDraftHost {
  readonly draft: string
  setDraft(draft: string): void
}

/** Like Desktop, wait 60 ms before asking the gateway (`use-live-completion-adapter.ts:43`). */
export const slashLookupDelayMs = 60

const hasWhitespace = (value: string): boolean => /\s/.test(value)

/**
 * One chat's slash-command list (the slash half of HermesKit's `ChatComposer`): the
 * catalog (`commands.catalog`), completions for the draft (`complete.slash`, cached per
 * text), the highlighted row and the keys that move and accept it.
 */
export class ComposerSlash extends Observable<ComposerSlashView> {
  catalog?: SlashCatalog
  private request = 0
  private loadRequest = 0
  /** The draft the user arrowed in: Return then takes the highlighted row. */
  private explicitText?: string
  /** A draft the list was dismissed for (Esc, or accepted as is): no list until it changes. */
  private suppressedText?: string
  private cache = new Map<string, SlashCompletions>()
  /** The text whose `complete.slash` failed: no answer is coming for it. */
  private failedText?: string
  private catalogFailure?: string
  private timer?: ReturnType<typeof setTimeout>

  constructor(private readonly session: ChatSession, private readonly host: SlashDraftHost) {
    super({ suggestions: [], selection: 0, isOpen: false })
  }

  private update(change: Partial<ComposerSlashView>): void {
    const next: ComposerSlashView = { ...this.get(), ...change }
    if (next.notice === undefined) delete next.notice
    this.set(next)
  }

  /** The rows with their headers and the highlight, from one snapshot of the list. */
  get rows(): SlashRow[] {
    return slashRows(this.get().suggestions, this.get().selection)
  }

  /** Loads the catalog, on opening a chat and again after a reconnect. */
  async loadCatalog(): Promise<SlashCatalog | undefined> {
    this.request += 1
    this.loadRequest += 1
    const request = this.loadRequest
    this.catalog = undefined
    this.cache = new Map()
    this.failedText = undefined
    this.catalogFailure = undefined
    this.close()
    try {
      const client = await this.session.liveClient()
      const catalog = new SlashCatalog(await client.call('commands.catalog', { session_id: this.session.sessionID }))
      if (request !== this.loadRequest) return catalog
      this.catalog = catalog
      await this.refresh()
      return catalog
    } catch (error) {
      if (request !== this.loadRequest) throw error
      this.catalogFailure = describeError(error)
      await this.refresh()
      throw error
    }
  }

  /** The catalog, loading it when there is none (for `runSlash`). */
  async requireCatalog(): Promise<SlashCatalog> {
    if (this.catalog) return this.catalog
    const catalog = await this.loadCatalog()
    if (!catalog) throw new Error('commands did not load')
    return catalog
  }

  /** Whether `refresh()` would ask the gateway for this draft, so the view waits a beat first. */
  get needsRequest(): boolean {
    const draft = this.host.draft
    if (!this.catalog || !isSlashCompletionCandidate(draft) || draft === '/' || draft === this.suppressedText ||
      !this.catalog.listsArguments(draft)) return false
    return !this.cache.has(draft.toLowerCase())
  }

  /** The draft changed: recompute the list, after `slashLookupDelayMs` when that asks the gateway. */
  draftChanged(): void {
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = undefined
    if (this.needsRequest) {
      this.request += 1
      this.timer = setTimeout(() => { this.timer = undefined; void this.refresh() }, slashLookupDelayMs)
    } else {
      void this.refresh()
    }
  }

  /** Stops a pending lookup (the chat went away). */
  cancel(): void {
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = undefined
    this.request += 1
  }

  /** Recomputes the list for the draft. Until a `complete.slash` answer lands, the old rows stay. */
  async refresh(): Promise<void> {
    this.request += 1
    const request = this.request
    const text = this.host.draft
    const catalog = this.catalog
    if (!catalog || !isSlashCompletionCandidate(text) || text === this.suppressedText || !catalog.listsArguments(text)) {
      this.close()
      if (!catalog && this.catalogFailure !== undefined && isSlashCompletionCandidate(text) && text !== this.suppressedText &&
        !hasWhitespace(text)) {
        this.update({ notice: `Couldn't load commands: ${this.catalogFailure}` })
      }
      return
    }
    let completions: SlashCompletions | undefined
    const load = this.loadRequest
    if (text !== '/') {
      completions = this.cache.get(text.toLowerCase())
      if (!completions) {
        try {
          const client = await this.session.liveClient()
          completions = new SlashCompletions(await client.call('complete.slash', { session_id: this.session.sessionID, text }), text)
          if (load === this.loadRequest) this.cache.set(text.toLowerCase(), completions)
        } catch (error) {
          if (load === this.loadRequest) this.failedText = text
          if (request !== this.request) return
          this.close()
          if (this.host.draft === text) this.update({ notice: `Couldn't look up commands: ${describeError(error)}` })
          return
        }
      }
    }
    if (request !== this.request || this.host.draft !== text) return
    // Keep the row the user arrowed to, if it is still listed.
    const { suggestions: old, selection: oldSelection } = this.get()
    const picked = this.explicitText === text ? old[oldSelection]?.text : undefined
    const suggestions = catalog.suggestions(text, completions)
    let selection = 0
    const kept = picked !== undefined ? suggestions.findIndex((row) => row.text === picked) : -1
    if (kept >= 0) selection = kept
    else this.explicitText = undefined
    this.update({
      suggestions, selection, isOpen: suggestions.length > 0,
      notice: suggestions.length === 0 && !hasWhitespace(text) ? 'No matches. Try /help.' : undefined,
    })
  }

  /** Tab is swallowed while a lookup is due, so it never moves focus out of the composer meanwhile. */
  get swallowsTab(): boolean {
    return !this.get().isOpen && this.needsRequest && this.host.draft !== this.failedText
  }

  dismiss(): void {
    this.suppressedText = this.host.draft
    this.close()
  }

  /** Sending or a new draft: the suppressed text no longer applies. */
  resetSuppression(): void {
    this.suppressedText = undefined
  }

  move(offset: number): void {
    const { isOpen, suggestions, selection } = this.get()
    if (!isOpen || suggestions.length === 0) return
    this.explicitText = this.host.draft
    this.update({ selection: (selection + offset + suggestions.length) % suggestions.length })
  }

  /**
   * A key the text area offers the list; true when the list took it.
   * - With rows: arrows move, Tab and Return accept (`acceptFromKey`), Esc closes.
   * - With no rows: Tab is swallowed while a lookup is due, and Esc clears a notice.
   */
  handleKey(key: SlashListKey): boolean {
    if (key === 'tab' && this.swallowsTab) return true
    if (!this.get().isOpen) {
      if (key !== 'escape' || this.get().notice === undefined) return false
      this.dismiss()
      return true
    }
    switch (key) {
      case 'up': this.move(-1); return true
      case 'down': this.move(1); return true
      case 'tab': case 'accept': return this.acceptFromKey(key === 'tab')
      case 'escape': this.dismiss(); return true
    }
  }

  /**
   * Tab or Return with rows: the highlighted row if the user arrowed to it, else the row
   * `implicitAcceptIndex` picks; in a free-text argument, Return sends what was typed.
   * False: the key is not the list's, so Return sends the draft.
   */
  acceptFromKey(isTab: boolean): boolean {
    const { isOpen, suggestions, selection } = this.get()
    const draft = this.host.draft
    if (!isOpen || suggestions.length === 0 || !isSlashCompletionCandidate(draft)) return false
    const explicit = this.explicitText === draft
    if (isTab) {
      this.accept(selection)
      return true
    }
    if (this.catalog?.isFreeTextArgument(draft) && !explicit) return false
    const index = implicitAcceptIndex(draft, suggestions.map((row) => row.text), selection, explicit)
    if (index === undefined) return false
    this.accept(index)
    return true
  }

  /** Accepts the clicked row. */
  acceptRow(id: string): void {
    const index = this.rows.findIndex((row) => row.id === id)
    if (index >= 0) this.accept(index)
  }

  /**
   * Puts the row's text into the draft (`use-composer-trigger.ts:375`). A command gets a
   * space after it, so an `options` or `mixed` command then lists its arguments; an
   * argument row is the whole `/command argument`, and the list stays closed until the
   * next edit.
   */
  accept(index = this.get().selection): void {
    const { isOpen, suggestions } = this.get()
    const row = suggestions[index]
    if (!isOpen || !row) return
    this.explicitText = undefined
    this.close()
    if (hasWhitespace(row.text)) {
      this.suppressedText = row.text
      this.host.setDraft(row.text)
    } else {
      this.host.setDraft(row.text + ' ')
    }
    this.draftChanged()
  }

  close(): void {
    const view = this.get()
    if (view.suggestions.length === 0 && view.selection === 0 && !view.isOpen && view.notice === undefined) return
    this.set({ suggestions: [], selection: 0, isOpen: false })
  }
}
