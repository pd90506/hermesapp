import { describe, expect, test } from 'vitest'
import {
  ClarifyForm, compressCommand, compressionMessage, heldCancelBlockedMessage, isCompressionNote,
  type ChatSession, type ClarifyRequest,
} from '../../src/index.ts'
import { PagedServer, completePayload, eventually, rows, FakeMessageStore } from '../support/paged-server.ts'

const texts = (chat: ChatSession) => chat.get().items.map((item) => `${item.role}:${item.text}`)

async function openWithTurn() {
  const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
  const connection = await server.connect()
  const chat = await connection.chats.openSession('default', { id: 'stored-1', title: 'Earlier' })
  chat.coalescesStreamedText = false
  await eventually(() => chat.get().paging.isLoaded)
  const composer = connection.chats.composer(chat)
  composer.setDraft('first')
  await composer.submit()
  server.event('message.start', chat.sessionID, 1)
  await eventually(() => chat.get().isRunning)
  return { server, connection, chat, composer }
}

describe('held prompts', () => {
  test('a message sent mid-reply waits in the app and goes out when the reply ends', async () => {
    const { server, chat, composer } = await openWithTurn()
    composer.setDraft('second')
    await composer.submit()
    expect(composer.draft).toBe('')
    expect(composer.queue.held.map((held) => held.text)).toEqual(['second'])
    expect(server.calls('prompt.submit').map((call) => call.text)).toEqual(['first'])
    expect(texts(chat)).not.toContain('user:second')

    // Behind a held one, the next waits too, in order.
    composer.setDraft('third')
    await composer.submit()
    expect(composer.queue.held.map((held) => held.text)).toEqual(['second', 'third'])

    server.event('message.complete', chat.sessionID, 2, completePayload('done', [3, 4]))
    expect(await eventually(() => server.calls('prompt.submit').length === 2)).toBe(true)
    expect(server.calls('prompt.submit')[1]).toMatchObject({ text: 'second' })
    expect(composer.queue.held.map((held) => held.text)).toEqual(['third'])
  })

  test('Cancel puts the text back only into an empty composer', async () => {
    const { composer } = await openWithTurn()
    composer.setDraft('later')
    await composer.submit()
    const id = composer.queue.held[0]!.id
    composer.setDraft('typing')
    expect(composer.queue.cancel(id)).toBe(false)
    expect(composer.get().error).toBe(heldCancelBlockedMessage)
    expect(composer.draft).toBe('typing')
    expect(composer.queue.held).toHaveLength(1)

    composer.setDraft('')
    expect(composer.queue.cancel(id)).toBe(true)
    expect(composer.draft).toBe('later')
    expect(composer.queue.held).toHaveLength(0)
  })

  test('Steer hands a held message to the running reply', async () => {
    const { server, chat, composer } = await openWithTurn()
    composer.setDraft('look at the tests too')
    await composer.submit()
    expect(composer.queue.canSteer).toBe(true)
    server.held.add('session.steer')
    const steering = composer.queue.steer(composer.queue.held[0]!.id)
    expect(composer.queue.held).toHaveLength(0)
    await eventually(() => server.heldFrames.length === 1)
    expect(server.heldFrames[0]?.params).toEqual({ session_id: chat.sessionID, text: 'look at the tests too' })
    server.answer(server.heldFrames[0]!, { status: 'queued' })
    await steering
    const steer = chat.get().items.at(-1)
    expect(steer).toMatchObject({ role: 'user', text: 'look at the tests too', displayKind: 'steer' })
    expect(server.calls('prompt.submit')).toHaveLength(1)
  })

  test('a failed steer keeps the message held, in its place', async () => {
    const { server, composer } = await openWithTurn()
    composer.setDraft('one')
    await composer.submit()
    composer.setDraft('two')
    await composer.submit()
    server.errors.set('session.steer', { code: -32000, message: 'boom' })
    await composer.queue.steer(composer.queue.held[1]!.id)
    expect(composer.queue.held.map((held) => held.text)).toEqual(['one', 'two'])
    expect(composer.get().error).toBeDefined()
  })

  test('a steer that finds no turn running goes as a normal prompt', async () => {
    const { server, chat, composer } = await openWithTurn()
    composer.setDraft('late')
    await composer.submit()
    server.held.add('session.steer')
    const steering = composer.queue.steer(composer.queue.held[0]!.id)
    await eventually(() => server.heldFrames.length === 1)
    server.held.clear()
    server.answer(server.heldFrames[0]!, { status: 'rejected' })
    await steering
    expect(server.calls('prompt.submit').map((call) => call.text)).toEqual(['first', 'late'])
    expect(texts(chat)).toContain('user:late')
  })
})

describe('compression', () => {
  test('/compress shows the card, holds what is sent meanwhile, then leaves its line', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const connection = await server.connect()
    const chat = await connection.chats.openSession('default', { id: 'stored-1' })
    await eventually(() => chat.get().paging.isLoaded)
    const composer = connection.chats.composer(chat)
    server.held.add('session.compress')
    composer.setDraft('/compress the API work')
    const compressing = composer.submit()
    expect(composer.draft).toBe('')
    expect(composer.queue.showsCompressing).toBe(true)
    expect(composer.queue.canSteer).toBe(false)
    await eventually(() => server.heldFrames.length === 1)
    expect(server.heldFrames[0]?.params).toEqual({ session_id: chat.sessionID, focus_topic: 'the API work' })

    // A second one while it runs is dropped.
    composer.setDraft('/compact')
    await composer.submit()
    composer.setDraft('after it')
    await composer.submit()
    expect(composer.queue.held.map((held) => held.text)).toEqual(['after it'])

    server.held.clear()
    server.answer(server.heldFrames[0]!, {
      status: 'compressed', removed: 90,
      summary: { headline: 'Compressed 120 → 30 messages', token_line: 'Approx request size 40k → 9k tokens' },
    })
    await compressing
    expect(composer.queue.showsCompressing).toBe(false)
    const note = chat.get().items.find(isCompressionNote)
    expect(note?.text).toBe('Compressed 120 → 30 messages\nApprox request size 40k → 9k tokens')
    expect(server.calls('session.compress')).toHaveLength(1)
    expect(await eventually(() => server.calls('prompt.submit').length === 1)).toBe(true)
    expect(server.calls('prompt.submit')[0]).toMatchObject({ text: 'after it' })
  })

  test('a compaction Hermes reports shows the card and holds sends', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const connection = await server.connect()
    const chat = await connection.chats.openSession('default', { id: 'stored-1' })
    await eventually(() => chat.get().paging.isLoaded)
    const composer = connection.chats.composer(chat)
    server.event('status.update', chat.sessionID, 1, { kind: 'compacting', text: 'Compacting…' })
    await eventually(() => chat.get().isCompacting)
    expect(composer.queue.showsCompressing).toBe(true)
    composer.setDraft('wait for it')
    await composer.submit()
    expect(composer.queue.held).toHaveLength(1)
    server.event('status.update', chat.sessionID, 2, { kind: 'compacted', text: '' })
    expect(await eventually(() => server.calls('prompt.submit').length === 1)).toBe(true)
  })

  test('the result line', () => {
    expect(compressionMessage({ status: 'pending', message: 'running on the compute host' })).toBe('running on the compute host')
    expect(compressionMessage({ status: 'pending' })).toBe('compression still running in the background')
    expect(compressionMessage({ compressed: false, message: 'another compression is running' })).toBe('another compression is running')
    expect(compressionMessage({ summary: { headline: 'Compressed 8 → 3', note: 'kept 1' } })).toBe('Compressed 8 → 3\nkept 1')
    expect(compressionMessage({ removed: 4 })).toBe('compressed 4 messages')
    expect(compressionMessage({})).toBe('nothing to compress')
    expect(compressionMessage(null)).toBe('nothing to compress')
  })

  test('which text is a compaction command', () => {
    expect(compressCommand('/compress')).toEqual({})
    expect(compressCommand('  /compact  ')).toEqual({})
    expect(compressCommand('/compress --keep 1')).toEqual({ topic: '--keep 1' })
    expect(compressCommand('/compressor')).toBeUndefined()
    expect(compressCommand('please /compress')).toBeUndefined()
  })
})

describe('clarify', () => {
  const request: ClarifyRequest = {
    session_id: 's',
    questions: [
      { qid: 'db', question: 'Which database?', choices: ['Postgres (Recommended)', 'SQLite', '  '] },
      { qid: 'tags', question: 'Which tags?', choices: ['api', 'ui', 'docs'], multi_select: true },
      { qid: 'name', question: 'Project name?' },
    ],
  }

  test('a single choice moves on; the answers go out together', () => {
    let form = ClarifyForm.start(request)
    expect(form.activeIndex).toBe(0)
    const [db, tags, name] = form.questions
    expect(form.canSend).toBe(false)
    form = form.pick('Postgres (Recommended)', db!)
    expect(form.activeIndex).toBe(1)
    form = form.pick('ui', tags!).pick('api', tags!).setOther('infra', tags!)
    expect(form.selection(tags!).choices).toEqual(['api', 'ui'])
    expect(form.activeIndex).toBe(1)
    expect(form.answeredCount).toBe(2)
    expect(form.answers).toEqual({ db: 'Postgres', tags: '["api","ui","infra"]', name: null })
    form = form.show(2).setOther('talaria', name!)
    expect(form.answers.name).toBe('talaria')
    // Typed text replaces a single choice.
    form = form.setOther('MySQL', db!)
    expect(form.answers.db).toBe('MySQL')
  })

  test('a replayed request starts from its locked answers', () => {
    const form = ClarifyForm.start({ ...request, answers: { db: 'SQLite', tags: '["docs","other"]' } })
    expect(form.activeIndex).toBe(2)
    expect(form.selection(form.questions[0]!).choices).toEqual(['SQLite'])
    expect(form.selection(form.questions[1]!)).toEqual({ choices: ['docs'], other: 'other' })
  })

  test('the card answers every question at once', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const connection = await server.connect()
    const chat = await connection.chats.openSession('default', { id: 'stored-1' })
    server.request('req-c', 'clarify', { ...request, session_id: chat.sessionID })
    await eventually(() => chat.get().pendingRequests.length === 1)
    chat.answerClarify(chat.get().pendingRequests[0]!, { db: 'SQLite', tags: null, name: null })
    expect(chat.get().pendingRequests).toHaveLength(0)
    expect(server.socket.sent.find((frame) => frame.id === 'req-c')).toMatchObject({
      result: { answers: { db: 'SQLite', tags: null, name: null } },
    })
    server.request('req-d', 'clarify', { ...request, session_id: chat.sessionID })
    await eventually(() => chat.get().pendingRequests.length === 1)
    chat.answerClarify(chat.get().pendingRequests[0]!, null)
    expect(server.socket.sent.find((frame) => frame.id === 'req-d')).toMatchObject({ result: { answers: null } })
  })
})
