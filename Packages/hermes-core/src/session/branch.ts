import type { GatewayConnection } from '../connection.ts'
import { ChatSession, HistoryReadError } from './chat-session.ts'
import type { TranscriptItem } from './items.ts'
import { storedItems, textOf, type ToolCalls } from './stored-projection.ts'
import type { SessionMessagesSource, StoredMessage } from './types.ts'

/**
 * Branch from a message (package G): a new chat holding the conversation up to that
 * message, as Desktop's "Branch in new chat" on a reply (`branchLoadedSession`,
 * `apps/desktop/src/app/session/hooks/use-session-actions/index.ts:2928-3002`; HermesKit's
 * `MessageBranch`).
 *
 * `session.branch` copies the parent's first `count` *visible* turns: its user and
 * assistant rows with text (`_visible_branch_history`,
 * `tui_gateway/methods_session_branch.py:21-25`). Desktop counts them in the stored
 * transcript, read whole, up to the clicked message's row (`selectBranchMessages`).
 */
export class MessageBranchError extends Error {
  constructor(readonly kind: 'busy' | 'messageNotFound' | 'botChat') {
    super(MessageBranchError.messages[kind])
    this.name = 'MessageBranchError'
  }

  static readonly messages = {
    busy: 'Stop the current reply, or wait for it to finish, then branch.',
    messageNotFound: "That message isn't saved in the chat yet. Try again in a moment.",
    botChat: "A bot's Bot Chat can't be branched.",
  } as const
}

/** `session.branch`'s answer (`session.create`'s shape). */
export interface SessionBranchResult {
  session_id: string
  stored_session_id: string
  message_count?: number | null
}

export const MessageBranch = {
  method: 'session.branch',
  /** Rows a page of the whole-transcript read (Desktop's `getAllSessionMessages`). */
  pageSize: 500,
  /** Most rows read from a gateway that pages but ignores `order`. */
  rowLimit: 20_000,

  /** Whether `session.branch` copies this stored row. */
  isCopied(row: StoredMessage): boolean {
    if (row.role !== 'user' && row.role !== 'assistant') return false
    return (textOf(row.content) ?? '').trim() !== ''
  },

  /**
   * The `count` that ends a branch at `item`: the copied rows up to and including its row
   * in `stored` (the whole stored transcript, oldest first). Undefined when its row isn't
   * there. The row is found by its id, else (a reply shown before its row was read back)
   * as Desktop does: the same role and text, counted from the end, among the rows as the
   * transcript shows them. `shown` is the transcript's items.
   */
  count(item: TranscriptItem, shown: readonly TranscriptItem[], stored: readonly StoredMessage[]): number | undefined {
    const index = rowIndex(item, shown, stored)
    if (index === undefined || !MessageBranch.isCopied(stored[index]!)) return undefined
    let count = 0
    for (let at = 0; at <= index; at += 1) if (MessageBranch.isCopied(stored[at]!)) count += 1
    return count
  },

  /** Whether a chat can be branched at all: not a bot's Bot Chat, which isn't copied. */
  canBranch(chat: ChatSession): boolean {
    return chat.kind !== 'botChat'
  },
} as const

function rowIndex(item: TranscriptItem, shown: readonly TranscriptItem[], rows: readonly StoredMessage[]): number | undefined {
  const found = (rowID: number | undefined) => {
    if (rowID === undefined) return undefined
    const index = rows.findIndex((row) => row.id === rowID)
    return index >= 0 ? index : undefined
  }
  if (item.rowID !== undefined) return found(item.rowID)
  const position = shown.findIndex((other) => other.id === item.id)
  if (position < 0) return undefined
  const matches = (other: TranscriptItem) => other.role === item.role && other.text === item.text
  // The how-many-th from the end such a message is on screen, and the row that is as far
  // from the end among the stored rows, projected as the transcript shows them.
  const fromEnd = shown.slice(position).filter(matches).length
  const toolCalls: ToolCalls = new Map()
  const candidates = storedItems(rows, toolCalls, true).filter(matches)
  if (fromEnd > candidates.length) return undefined
  return found(candidates[candidates.length - fromEnd]!.rowID)
}

/**
 * The whole stored transcript, oldest first, `MessageBranch.pageSize` rows a page, as
 * Desktop reads it to branch (`getAllSessionMessages`).
 */
export async function readAllStoredRows(source: SessionMessagesSource, sessionID: string, profile?: string): Promise<StoredMessage[]> {
  const rows: StoredMessage[] = []
  const seen = new Set<number>()
  for (;;) {
    if (rows.length >= MessageBranch.rowLimit) throw new HistoryReadError('tooLong', MessageBranch.rowLimit)
    const page = await source.messagesPage({
      sessionID, order: 'oldest', limit: MessageBranch.pageSize, offset: rows.length,
      ...(profile !== undefined ? { profile } : {}),
    })
    const fresh = page.messages.filter((row) => typeof row.id !== 'number' || (!seen.has(row.id) && (seen.add(row.id), true)))
    rows.push(...fresh)
    // A gateway that predates paging sends everything at once; a short page is the last.
    const limit = page.pagination?.limit ?? 0
    if (!(limit > 0 && page.messages.length >= limit)) break
    if (fresh.length === 0) throw new HistoryReadError('noProgress')
  }
  return rows
}

/**
 * Branches `chat` into a new chat ending at `item` (a reply or prompt shown in it), on
 * the chat's live runtime, and opens the branch. Refused while a turn runs, as Desktop
 * does. The gateway names the branch after the parent's lineage ("Title #2").
 */
export async function branchChat(connection: GatewayConnection, chat: ChatSession, item: TranscriptItem,
  newKey: () => string = randomKey): Promise<ChatSession> {
  if (!MessageBranch.canBranch(chat)) throw new MessageBranchError('botChat')
  if (chat.get().isRunning) throw new MessageBranchError('busy')
  const source = chat.messagesSource
  const key = chat.storedSessionID
  if (!source || key === undefined) throw new MessageBranchError('messageNotFound')
  const rows = await readAllStoredRows(source, key, chat.profile)
  const count = MessageBranch.count(item, chat.get().items, rows)
  if (count === undefined) throw new MessageBranchError('messageNotFound')
  const client = await chat.liveClient()
  const branched = await client.call(MessageBranch.method, {
    session_id: chat.sessionID, count, idempotency_key: newKey(),
  }) as unknown as SessionBranchResult
  connection.refreshListsInBackground()
  // `session.resume` reuses the runtime the branch started on this socket. Every chat the
  // app opens has its profile (a row, a Bot Chat or a New chat of one).
  return connection.chats.openSession(chat.profile ?? 'default', { id: branched.stored_session_id })
}

/** A random key for `idempotency_key`: a retry with it gets the same branch, not a second. */
function randomKey(): string {
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16))
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}
