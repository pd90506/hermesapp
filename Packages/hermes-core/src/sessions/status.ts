/**
 * What one chat is doing, as its sidebar row shows it (HermesKit's `ChatStatus`, from
 * Desktop's session dot, `apps/desktop/src/store/session-dot-state.ts`). The loudest
 * first: a question for the user, then a running turn, then work left in the background.
 */
export type ChatStatus = 'idle' | 'background' | 'working' | 'waitingForYou'

export function resolveChatStatus(waiting: boolean, running: boolean, background: boolean): ChatStatus {
  if (waiting) return 'waitingForYou'
  if (running) return 'working'
  return background ? 'background' : 'idle'
}

/** Desktop's labels (`sidebar.row`, `apps/desktop/src/i18n/en.ts:3228-3232`). */
export const chatStatusLabel: Record<ChatStatus, string> = {
  idle: '',
  background: 'Background task running',
  working: 'Session running',
  waitingForYou: 'Waiting for your answer',
}

/** A chat with a question waiting for the user (HermesKit's `WaitingChat`). */
export interface WaitingChat {
  /** Its runtime id. */
  sessionID: string
  storedSessionID?: string
  profile?: string
  isBotChat: boolean
}

/**
 * What the live chats report to the sidebar: the chat core (package A) sets one with
 * `SessionSidebar.setLiveStatus`. Until then every row is idle and nothing waits.
 */
export interface LiveChatStatus {
  /** The row's chat, when open here (on screen or kept warm). */
  status(profile: string, storedID: string): ChatStatus
  /** The Bot Chat's status for a profile. */
  botChatStatus(profile: string): ChatStatus
  /** Chats with a question for the user that isn't on screen, in the order they asked. */
  waitingChats(): WaitingChat[]
  /** When the user last sent from here in that chat (epoch ms): it counts before the next read. */
  lastPromptAt?(profile: string, storedID: string): number | undefined
  /** The runtime id of the row's chat when it is open here: only an open chat can be renamed (`session.title`). */
  runtimeID?(profile: string, storedID: string): string | undefined
  /** Called on any change. */
  subscribe(listener: () => void): () => void
}
