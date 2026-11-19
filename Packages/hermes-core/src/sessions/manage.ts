import { Bot, botChatTitle, type SessionSummary } from '../bots.ts'
import type { JSONValue } from '../protocol/jsonrpc.ts'
import { RPCError } from '../protocol/jsonrpc.ts'

/** Why a rename, archive, fork or delete was refused before anything was sent (HermesKit's `SessionActionError`). */
export class SessionActionError extends Error {
  constructor(readonly kind: 'botChatProtected' | 'reservedTitle' | 'emptyTitle' | 'notOpen') {
    super(messages[kind])
  }
}

const messages: Record<SessionActionError['kind'], string> = {
  botChatProtected: 'The Bot Chat can’t be renamed, archived or deleted.',
  reservedTitle: '“Bot Chat” is the name of the profile’s own chat.',
  emptyTitle: 'Type a title.',
  notOpen: 'Open the chat to rename it.',
}

/** The calls the actions make, on the connection (`GatewayConnection.call`). */
export type Call = (method: string, params: JSONValue) => Promise<JSONValue>

/**
 * Is this row a bot's Bot Chat? Those are protected: the gateway only refuses renaming a
 * hidden "Bot Chat" (`hermes_state_titles.py:100-109`), archive and delete would retire it.
 */
export function isProtected(row: SessionSummary, bot: Bot | undefined): boolean {
  return Bot.isBotChat(row, bot)
}

/**
 * Side-chat management over the gateway's JSON-RPC (`docs/protocol.md` §10.9; HermesKit's
 * `GatewayConnection+Manage`), never the dashboard REST API.
 */
export const SessionActions = {
  /** `session.archive` (`methods_session.py:1252-1279`): leaves the lists, keeps its messages. */
  async archive(call: Call, row: SessionSummary, profile: string, bot: Bot | undefined, archived = true): Promise<void> {
    if (isProtected(row, bot)) throw new SessionActionError('botChatProtected')
    await call('session.archive', { session_id: row.id, archived, profile })
  },

  /**
   * `session.delete` (`methods_session.py:1175-1198`). A chat live on this socket is closed
   * by the chat core first (a live session refuses with 4023). 4007 counts as done.
   */
  async delete(call: Call, row: SessionSummary, profile: string, bot: Bot | undefined): Promise<void> {
    if (isProtected(row, bot)) throw new SessionActionError('botChatProtected')
    try {
      await call('session.delete', { session_id: row.id, profile })
    } catch (error) {
      if (!(error instanceof RPCError && error.code === 4007)) throw error
    }
  },

  /**
   * Fork: copies a stored session into a new one (`session.branch_stored`), stored under
   * `desktop` as a new chat is. The gateway names it "Title #2". Returns the copy's stored id.
   */
  async fork(call: Call, row: SessionSummary, profile: string, bot: Bot | undefined): Promise<string> {
    if (isProtected(row, bot)) throw new SessionActionError('botChatProtected')
    const result = await call('session.branch_stored', { parent_session_id: row.id, profile, source: 'desktop' }) as
      { stored_session_id?: string }
    return result.stored_session_id ?? ''
  },

  /**
   * Rename: `session.title` on a chat's live runtime id (`methods_session.py:1220-1249`).
   * Only a chat open here can be renamed: attaching to a row just to rename it would take
   * its events from another client. `runtimeID` comes from the chat core; undefined
   * refuses with `notOpen`.
   */
  async rename(call: Call, row: SessionSummary, bot: Bot | undefined, title: string, runtimeID: string | undefined): Promise<string> {
    const trimmed = title.trim()
    if (!trimmed) throw new SessionActionError('emptyTitle')
    if (isProtected(row, bot)) throw new SessionActionError('botChatProtected')
    if (trimmed.toLowerCase() === botChatTitle.toLowerCase()) throw new SessionActionError('reservedTitle')
    if (!runtimeID) throw new SessionActionError('notOpen')
    const result = await call('session.title', { session_id: runtimeID, title: trimmed }) as { title?: string }
    return result.title ?? trimmed
  },
}
