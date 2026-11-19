/** What a key press in the composer does. */
export type ComposerKeyAction = 'send' | 'newline' | 'none'

export interface ComposerKey {
  key: string
  shiftKey: boolean
  altKey: boolean
  metaKey: boolean
  ctrlKey: boolean
  /** An input method is composing (`KeyboardEvent.isComposing`, or key code 229). */
  isComposing: boolean
}

/**
 * The Mac composer's keys (`ComposerTextView`): Return sends; Shift- or Option-Return
 * (Alt on Windows) inserts a line break; ⌘↩ / Ctrl+Enter also sends; while an input
 * method composes, Return is the input method's and never sends.
 */
export function composerKeyAction(event: ComposerKey): ComposerKeyAction {
  if (event.key !== 'Enter' || event.isComposing) return 'none'
  if (event.metaKey || event.ctrlKey) return 'send'
  if (event.shiftKey || event.altKey) return 'newline'
  return 'send'
}
