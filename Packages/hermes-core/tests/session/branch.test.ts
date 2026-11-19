import { describe, expect, test } from 'vitest'
import {
  MessageBranch, MessageBranchError, branchChat, makeItem, storedItems, type StoredMessage, type TranscriptItem,
} from '../../src/index.ts'
import { FakeMessageStore, PagedServer, eventually } from '../support/paged-server.ts'

const row = (id: number, role: string, text: string | null): StoredMessage => ({ id, role, ...(text !== null ? { content: text } : {}) })

/** A turn with a tool call between its two replies, as Hermes stores it. */
const stored: StoredMessage[] = [
  row(1, 'user', 'first'),
  row(2, 'assistant', 'Looking.'),
  row(3, 'assistant', null),
  row(4, 'tool', '{"ok":true}'),
  row(5, 'assistant', 'Found it.'),
  row(6, 'user', 'second'),
  row(7, 'assistant', 'Done.'),
]

const shown = (rows: StoredMessage[]): TranscriptItem[] => storedItems(rows, new Map(), true)

describe('the branch count', () => {
  test('counts the copied rows through the message row', () => {
    const items = shown(stored)
    const count = (rowID: number) => MessageBranch.count(items.find((item) => item.rowID === rowID)!, items, stored)
    expect(count(2)).toBe(2)
    expect(count(5)).toBe(3)
    expect(count(7)).toBe(5)
    expect(count(6)).toBe(4)
  })

  test('a live reply is found by its text, from the end', () => {
    const rows = [...stored, row(8, 'user', 'again'), row(9, 'assistant', 'Done.')]
    const items = [...shown(rows.slice(0, -1)), makeItem('live-1', 'assistant', 'Done.')]
    expect(MessageBranch.count(items.at(-1)!, items, rows)).toBe(7)
  })

  test('a message not stored yet has no count', () => {
    const items = [...shown(stored), makeItem('live-1', 'assistant', 'Not stored')]
    expect(MessageBranch.count(items.at(-1)!, items, stored)).toBeUndefined()
    expect(MessageBranch.count({ ...makeItem('row-99', 'assistant', 'Gone'), rowID: 99 }, items, stored)).toBeUndefined()
  })
})

describe('branching a chat', () => {
  async function open() {
    const server = new PagedServer(new FakeMessageStore(stored))
    const connection = await server.connect()
    const chat = await connection.chats.openSession('default', { id: 'stored-1', title: 'Earlier' })
    await eventually(() => chat.get().paging.isLoaded)
    return { server, connection, chat }
  }

  test('a branch is made on the live runtime with the count, and opened', async () => {
    const { server, connection, chat } = await open()
    const reply = chat.get().items.find((item) => item.rowID === 5)!
    server.held.add('session.branch')
    const branching = branchChat(connection, chat, reply, () => 'key-1')
    await eventually(() => server.heldFrames.length === 1)
    const frame = server.heldFrames[0]!
    expect(frame.params).toEqual({ session_id: chat.sessionID, count: 3, idempotency_key: 'key-1' })
    // The whole transcript was read, oldest first, to count.
    expect(server.store.queries.some((query) => query.order === 'oldest' && (query.offset ?? 0) === 0)).toBe(true)
    server.held.clear()
    server.answer(frame, { session_id: 'rt-b', stored_session_id: 'branch-1', message_count: 3 })
    const branch = await branching
    expect(branch.storedSessionID).toBe('branch-1')
    expect(connection.chats.active).toBe(branch)
    expect(server.calls('session.resume').at(-1)).toMatchObject({ session_id: 'branch-1', profile: 'default' })
  })

  test('a running chat is not branched', async () => {
    const { server, connection, chat } = await open()
    const reply = chat.get().items.find((item) => item.rowID === 7)!
    await chat.send('third')
    server.event('message.start', chat.sessionID, 1)
    expect(await eventually(() => chat.get().isRunning)).toBe(true)
    await expect(branchChat(connection, chat, reply)).rejects.toEqual(new MessageBranchError('busy'))
    expect(server.calls('session.branch')).toHaveLength(0)
  })
})
