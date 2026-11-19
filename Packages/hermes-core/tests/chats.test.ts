import { describe, expect, test } from 'vitest'
import { ChatSession, GatewayClientError, MessagesBelow, PaintBudget, messageDay, transcriptBlocks } from '../src/index.ts'
import { PagedServer, completePayload, eventually, rows, storedRow, FakeMessageStore } from './support/paged-server.ts'

const texts = (chat: ChatSession) => chat.get().items.map((item) => `${item.role}:${item.text}`)

async function openStored(server: PagedServer) {
  const connection = await server.connect()
  const chat = await connection.chats.openSession('default', { id: 'stored-1', title: 'Earlier' })
  chat.coalescesStreamedText = false
  await eventually(() => chat.get().paging.isLoaded)
  return { connection, chat }
}

describe('opening chats', () => {
  test('a session row resumes its stored key and reads the newest page', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 300)))
    const { connection, chat } = await openStored(server)
    expect(connection.chats.active).toBe(chat)
    expect(server.calls('session.resume')[0]).toMatchObject({
      session_id: 'stored-1', source: 'desktop', profile: 'default', omit_messages: true, defer_history: true,
    })
    const view = chat.get()
    expect(view.items).toHaveLength(ChatSession.pageSize)
    expect(view.items.at(-1)?.text).toBe('row 300')
    expect(view.paging.hasOlder).toBe(true)
    expect(view.title).toBe('Earlier')
    // The older page overlaps the loaded one a little (`olderPageOverlap`); no row shows twice.
    await chat.loadOlderMessages()
    const ids = chat.get().items.map((item) => item.rowID)
    expect(new Set(ids).size).toBe(ids.length)
    expect(chat.get().items[0]?.text).toBe('row 71')
    expect(chat.get().items.at(-1)?.text).toBe('row 300')
  })

  test('the pane shows the chat being opened until it is on screen', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 4)))
    const connection = await server.connect()
    server.held.add('session.resume')
    const opening = connection.chats.openSession('default', { id: 'stored-1', title: 'Earlier' })
    await eventually(() => server.heldFrames.length === 1)
    expect(connection.chats.get().opening).toEqual({ profile: 'default', kind: 'sideChat', title: 'Earlier' })
    server.held.clear()
    server.answer(server.heldFrames[0]!, { session_id: 'rt-9', session_key: 'stored-1', hydrating: true, info: {} })
    const chat = await opening
    expect(connection.chats.get().opening).toBeUndefined()
    expect(connection.chats.active).toBe(chat)
  })

  test('the Bot Chat is found by its exact title, hidden rows included, and its tip resumed', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 4)))
    server.botTip = 'coder-tip'
    const connection = await server.connect()
    const chat = await connection.chats.openBotChat('coder')
    expect(chat.kind).toBe('botChat')
    const lookup = server.calls('session.list').find((params) => params.title === 'Bot Chat')
    expect(lookup).toMatchObject({ include_hidden: true, profile: 'coder' })
    expect(server.calls('session.resume').at(-1)).toMatchObject({ session_id: 'coder-tip', profile: 'coder' })
    expect(server.calls('session.create')).toHaveLength(0)
  })

  test('a bot with no Bot Chat gets one, created hidden and titled at once', async () => {
    const server = new PagedServer()
    server.botTip = undefined
    const connection = await server.connect()
    const chat = await connection.chats.openBotChat('coder')
    expect(server.calls('session.create')[0]).toMatchObject({
      title: 'Bot Chat', source: 'desktop', profile: 'coder', hidden: true, follow_profile_config: true,
    })
    expect(server.calls('session.title')[0]).toMatchObject({ session_id: chat.sessionID, title: 'Bot Chat' })
  })

  test('New chat creates a desktop session, and comes back while nothing was sent in it', async () => {
    const server = new PagedServer()
    const connection = await server.connect()
    const first = await connection.chats.newChat('coder')
    expect(server.calls('session.create')[0]).toEqual({ source: 'desktop', profile: 'coder' })
    connection.chats.composer(first).setDraft('half typed')
    await connection.chats.openSession('default', { id: 'stored-1' })
    const again = await connection.chats.newChat('coder')
    expect(again).toBe(first)
    expect(server.calls('session.create')).toHaveLength(1)
    expect(connection.chats.composer(again).draft).toBe('half typed')
  })

  test('each chat keeps its own draft', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { connection, chat } = await openStored(server)
    connection.chats.composer(chat).setDraft('for the first')
    const other = await connection.chats.newChat('coder')
    expect(connection.chats.composer(other).draft).toBe('')
    await connection.chats.openSession('default', { id: 'stored-1' })
    expect(connection.chats.composer(chat).draft).toBe('for the first')
  })
})

describe('a turn', () => {
  test('streams, completes, and the stored rows replace the live ones', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 4)))
    const { chat } = await openStored(server)
    const sid = chat.sessionID
    await chat.send('hello')
    expect(server.calls('prompt.submit')[0]).toEqual({ session_id: sid, text: 'hello' })
    expect(texts(chat).at(-1)).toBe('user:hello')
    server.event('message.start', sid, 1)
    server.event('message.delta', sid, 2, { text: 'Hi ' })
    server.event('message.delta', sid, 3, { text: 'there' })
    await eventually(() => texts(chat).at(-1) === 'assistant:Hi there')
    expect(chat.get().isRunning).toBe(true)
    server.store.append([storedRow(6, 'assistant', 'Hi there')])
    server.event('message.complete', sid, 4, completePayload('Hi there', [5, 6]))
    expect(await eventually(() => !chat.get().isRunning && chat.get().items.at(-1)?.rowID === 6)).toBe(true)
    expect(texts(chat).slice(-2)).toEqual(['user:hello', 'assistant:Hi there'])
    expect(chat.lastSeq).toBe(4)
  })

  test('Stop interrupts the session', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { chat } = await openStored(server)
    await chat.send('long job')
    server.event('message.start', chat.sessionID, 1)
    await chat.interrupt()
    expect(server.calls('session.interrupt')).toEqual([{ session_id: chat.sessionID }])
  })

  test('a send cancelled before it went out takes its bubble back and gives the text to the composer', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { connection, chat } = await openStored(server)
    const composer = connection.chats.composer(chat)
    // The chat is still being bound to the socket: the send waits.
    let release!: () => void
    chat.identityGate = new Promise((resolve) => { release = resolve })
    composer.setDraft('never mind')
    const submitting = composer.submit()
    expect(composer.draft).toBe('')
    expect(texts(chat).at(-1)).toBe('user:never mind')
    composer.cancelSubmit()
    release()
    await submitting
    expect(composer.draft).toBe('never mind')
    expect(texts(chat)).not.toContain('user:never mind')
    expect(server.calls('prompt.submit')).toHaveLength(0)
  })

  test('a send while offline keeps the text in the composer', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { connection, chat } = await openStored(server)
    await connection.disconnect()
    const composer = connection.chats.composer(chat)
    composer.setDraft('offline')
    await composer.submit()
    expect(composer.draft).toBe('offline')
    expect(composer.get().error).toBe('Not connected to the gateway.')
  })
})

describe('server requests', () => {
  test('an approval card shows on its chat and its answer goes back', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { chat } = await openStored(server)
    server.request('req-1', 'approval', { session_id: chat.sessionID, request_id: 'a1', command: 'rm -rf build' })
    await eventually(() => chat.get().pendingRequests.length === 1)
    chat.answerApproval(chat.get().pendingRequests[0]!, 'once')
    expect(chat.get().pendingRequests).toHaveLength(0)
    const answer = server.socket.sent.find((frame) => frame.id === 'req-1')
    expect(answer).toMatchObject({ result: { choice: 'once' } })
  })

  test('a request of a chat not on screen waits for it', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { connection } = await openStored(server)
    server.request('req-2', 'sudo', { session_id: 'rt-elsewhere' })
    await eventually(() => connection.chats.get().otherRequests.length === 1)
    expect(connection.chats.get().otherRequests[0]?.id).toBe('req-2')
  })
})

describe('reconnecting', () => {
  test('on the same backend the chat reattaches and replays what it missed', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { connection, chat } = await openStored(server)
    const sid = chat.sessionID
    server.event('message.start', sid, 1)
    await eventually(() => chat.lastSeq === 1)
    server.replay = { events: [{ type: 'message.delta', session_id: sid, seq: 2, payload: { text: 'missed' } }], latest_seq: 2 }
    server.socket.drop()
    expect(await eventually(() => connection.get().link.phase === 'connected' && server.sockets.length === 2)).toBe(true)
    expect(server.calls('session.events.since')).toEqual([{ session_id: sid, last_seen: 1 }])
    expect(server.calls('session.resume')).toHaveLength(1)
    expect(chat.sessionID).toBe(sid)
    expect(await eventually(() => texts(chat).at(-1) === 'assistant:missed')).toBe(true)
  })

  test('on a restarted backend the chat resumes its stored key', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { connection, chat } = await openStored(server)
    server.event('message.start', chat.sessionID, 1)
    await eventually(() => chat.lastSeq === 1)
    server.epoch = 'E2'
    server.socket.drop()
    expect(await eventually(() => connection.get().link.phase === 'connected' && server.sockets.length === 2)).toBe(true)
    expect(server.calls('session.events.since')).toHaveLength(0)
    expect(server.calls('session.resume').at(-1)).toMatchObject({ session_id: 'stored-1', profile: 'default' })
    expect(chat.sessionID).toBe('rt-2')
    expect(connection.chats.active).toBe(chat)
  })

  test('a reclaimed runtime resumes on the next send', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { chat } = await openStored(server)
    server.event('session.reclaimed', chat.sessionID, undefined, { session_id: chat.sessionID, reason: 'idle' })
    await eventually(() => chat.isRuntimeGone)
    await chat.send('still there?')
    expect(chat.sessionID).toBe('rt-2')
    expect(server.calls('prompt.submit').at(-1)).toEqual({ session_id: 'rt-2', text: 'still there?' })
  })

  test('going back to a warm chat binds it to the socket again', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { connection, chat } = await openStored(server)
    await connection.chats.newChat('coder')
    const back = await connection.chats.openSession('default', { id: 'stored-1' })
    expect(back).toBe(chat)
    await chat.revisitTask
    expect(server.calls('session.activate')).toEqual([{ session_id: chat.sessionID, omit_messages: true }])
  })
})

describe('the list', () => {
  test('queued prompts wait above the composer, not in the list', () => {
    const items = [
      { id: 'a', role: 'user', text: 'one', outgoingStatus: 'Queued' },
      { id: 'b', role: 'assistant', text: 'two' },
    ] as never
    expect(transcriptBlocks(items).map((block) => block.id)).toEqual(['b'])
  })

  test('messages below the screen are counted for the scroll button', () => {
    const items = ['user', 'assistant', 'tool', 'assistant', 'user'].map((role, index) =>
      ({ id: `i${index}`, role, text: 'x', reasoning: '', images: [], attachments: [], attachmentPaths: [], isActive: false, isInterim: false })) as never
    const blocks = transcriptBlocks(items)
    expect(MessagesBelow.count(blocks, new Set(['i0']))).toBe(3)
    expect(MessagesBelow.title(3)).toBe('3 messages')
    expect(MessagesBelow.title(0)).toBe('Scroll to bottom')
    expect(PaintBudget.firstPaintStart(blocks)).toBe(0)
  })

  test('message days', () => {
    const now = new Date(2026, 10, 19, 10)
    expect(messageDay(new Date(2026, 10, 19, 1), now)).toBe('today')
    expect(messageDay(new Date(2026, 10, 18, 23), now)).toBe('yesterday')
    expect(messageDay(new Date(2026, 9, 1), now)).toBe('earlier')
  })

  test('not connected is reported, not thrown away', async () => {
    const server = new PagedServer()
    const connection = await server.connect()
    await connection.disconnect()
    await expect(connection.chats.newChat('coder')).rejects.toBeInstanceOf(GatewayClientError)
  })
})
