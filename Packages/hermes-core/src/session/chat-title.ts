import type { ChatKind } from './chat-session.ts'

/** A bot as the title names it. */
export interface TitledBot {
  name: string
  displayName: string
}

/**
 * The chat pane's title (the Mac's `RootView.chatTitle`): a session's title, a Bot Chat's
 * bot, or "title · bot" for a side chat. A chat being opened is named the same way from
 * what its open knows.
 */
export function chatTitle(chat: { kind: ChatKind; title?: string; profile?: string }, bots: readonly TitledBot[],
  opening = false): string {
  const bot = bots.find((candidate) => candidate.name === chat.profile)?.displayName ?? chat.profile
  const title = chat.title?.trim() ?? ''
  switch (chat.kind) {
    case 'botChat': return bot ?? 'Hermes'
    case 'sideChat': {
      const side = title || 'Side chat'
      return bot ? `${side} · ${bot}` : side
    }
    case 'session': return title || (opening ? 'Chat' : 'New Chat')
  }
}
