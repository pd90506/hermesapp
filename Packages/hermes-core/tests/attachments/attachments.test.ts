import { describe, expect, test } from 'vitest'
import {
  ClipboardPolicy, FileAttachmentPolicy, ImageAttachmentPolicy, OriginalFileNames, StrandedImages, attachmentDisplayName, attachmentID, base64, fileRefPath, formatBytes,
  type ChatSession, type ComposerImage,
} from '../../src/index.ts'
import { PagedServer, eventually, rows, FakeMessageStore } from '../support/paged-server.ts'

const png = (name = 'shot.png', size = 8): ComposerImage => ({ id: attachmentID(), filename: name, bytes: new Uint8Array(size).fill(7) })

async function openStored(server: PagedServer) {
  const connection = await server.connect()
  const chat = await connection.chats.openSession('default', { id: 'stored-1', title: 'Earlier' })
  chat.coalescesStreamedText = false
  await eventually(() => chat.get().paging.isLoaded)
  return { connection, chat, composer: connection.chats.composer(chat) }
}

const texts = (chat: ChatSession) => chat.get().items.map((item) => `${item.role}:${item.text}`)

describe('policies', () => {
  test('sizes read like Finder', () => {
    expect(formatBytes(512)).toBe('512 bytes')
    expect(formatBytes(14_200)).toBe('14 KB')
    expect(formatBytes(2_400_000)).toBe('2.4 MB')
  })

  test('only PNG, JPEG, GIF and WebP go unchanged', () => {
    expect(ImageAttachmentPolicy.canSendUnchanged('a.PNG')).toBe(true)
    expect(ImageAttachmentPolicy.canSendUnchanged('IMG_1.heic')).toBe(false)
    expect(ImageAttachmentPolicy.filename('IMG_0001.HEIC', 'jpg')).toBe('IMG_0001.jpg')
    expect(ImageAttachmentPolicy.rejection('a.png', 0)).toBe('a.png is empty.')
    expect(ImageAttachmentPolicy.rejection('a.png', 26 * 1024 * 1024)).toMatch(/too large/)
    expect(FileAttachmentPolicy.rejection(51 * 1024 * 1024)).toMatch(/limit is 50 MB/)
  })

  test('re-encoding tries native size, then 4096 and 2048 px', () => {
    expect(ImageAttachmentPolicy.encodeAttempts(1000, 6000, 4000, false))
      .toEqual([{ format: 'jpeg' }, { maxPixels: 4096, format: 'jpeg' }, { maxPixels: 2048, format: 'jpeg' }])
    expect(ImageAttachmentPolicy.encodeAttempts(30 * 1024 * 1024, 3000, 2000, true))
      .toEqual([{ maxPixels: 2048, format: 'png' }, { maxPixels: 2048, format: 'jpeg' }])
    // A small image whose source alone is over the cap: one JPEG frame.
    expect(ImageAttachmentPolicy.encodeAttempts(30 * 1024 * 1024, 800, 600, false)).toEqual([{ format: 'jpeg' }])
  })

  test('a paste of files attaches them; real text stays text', () => {
    expect(ClipboardPolicy.decide({ fileCount: 1 })).toBe('files')
    expect(ClipboardPolicy.decide({ fileCount: 1, text: 'https://example.com/cat.png' })).toBe('files')
    expect(ClipboardPolicy.decide({ fileCount: 1, text: 'report.pdf', fileNames: ['report.pdf'] })).toBe('files')
    expect(ClipboardPolicy.decide({ fileCount: 1, text: 'Q1\t10\nQ2\t12' })).toBe('text')
    expect(ClipboardPolicy.decide({ fileCount: 0, text: 'hello' })).toBe('text')
    expect(ClipboardPolicy.decide({ fileCount: 1, text: 'TODO:fix' })).toBe('text')
  })

  test('a file reference keeps its path', () => {
    expect(fileRefPath({ id: '1', name: 'a b.pdf', storedName: 'a b.pdf', byteCount: 1, refText: '@file:`attachments/a b.pdf`' })).toBe('attachments/a b.pdf')
    expect(fileRefPath({ id: '2', name: 'c.csv', storedName: 'c.csv', byteCount: 1, refText: '@file:/srv/c.csv' })).toBe('/srv/c.csv')
  })

  test('base64 matches the standard alphabet', () => {
    expect(base64(new TextEncoder().encode('hermes?'))).toBe('aGVybWVzPw==')
  })
})

describe('sending with attachments', () => {
  test('an image uploads when attached; Send only submits, and the bubble shows it', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { chat, composer } = await openStored(server)
    const image = png()
    expect(composer.attachments.attachImage(image)).toBe(true)
    expect(composer.canSubmit).toBe(false)
    await composer.attachments.uploadsSettled()
    expect(server.calls('image.attach_bytes')).toEqual([
      { session_id: chat.sessionID, content_base64: base64(image.bytes), filename: 'shot.png', profile: 'default' },
    ])
    expect(composer.canSubmit).toBe(true)
    await composer.submit()
    expect(server.calls('image.attach_bytes')).toHaveLength(1)
    expect(server.calls('prompt.submit').at(-1)).toEqual({ session_id: chat.sessionID, text: '' })
    // The stored row names the uploaded path, so it shows the thumbnail cached under it.
    const row = chat.get().items.findLast((item) => item.role === 'user')
    expect(row?.images[0]?.path).toMatch(/^\/home\/h\/\.hermes\/images\/\d+-shot\.png$/)
    expect(row?.text).toBe('')
    expect(composer.attachments.get().images).toHaveLength(0)
  })

  test('while the prompt goes out, its bubble shows the image this device has', async () => {
    const server = new PagedServer()
    const { chat, composer } = await openStored(server)
    const image = png()
    composer.attachments.attachImage(image)
    server.held.add('prompt.submit')
    const sending = composer.submit()
    await eventually(() => server.heldFrames.length === 1)
    const bubble = chat.get().items.findLast((item) => item.role === 'user')
    expect(bubble?.images[0]).toMatchObject({ name: 'shot.png', localID: image.id, position: 0 })
    expect(bubble?.images[0]?.path).toMatch(/shot\.png$/)
    server.held.clear()
    server.answer(server.heldFrames[0]!, { status: 'streaming' })
    await sending
  })

  test('files go as references in front of the text', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { chat, composer } = await openStored(server)
    expect(await composer.attachments.attachFile(new TextEncoder().encode('%PDF'), 'report.pdf', 'application/pdf')).toBe(true)
    expect(server.calls('file.attach')[0]).toEqual({
      session_id: chat.sessionID, name: 'report.pdf', data_url: 'data:application/pdf;base64,JVBERg==',
    })
    composer.setDraft('summarize this')
    await composer.submit()
    expect(server.calls('prompt.submit').at(-1)?.text).toBe('@file:attachments/report.pdf\n\nsummarize this')
    const bubble = chat.get().items.findLast((item) => item.role === 'user')
    expect(bubble?.attachments).toEqual(['report.pdf'])
    expect(bubble?.text).toBe('summarize this')
  })

  test('a renamed file still shows the name the user gave it', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { chat, composer } = await openStored(server)
    const bytes = new TextEncoder().encode('hi')
    await composer.attachments.attachFile(bytes, 'notes.txt', 'text/plain')
    await composer.attachments.attachFile(bytes, 'notes.txt', 'text/plain')
    expect(composer.attachments.get().files.map((file) => [file.name, file.storedName])).toEqual([['notes.txt', 'notes.txt'], ['notes.txt', 'notes-2.txt']])
    await composer.submit()
    expect(server.calls('prompt.submit').at(-1)?.text).toBe('@file:attachments/notes.txt\n@file:attachments/notes-2.txt')
    expect(chat.get().items.findLast((item) => item.role === 'user')?.attachments).toEqual(['notes.txt', 'notes.txt'])
    // A stored row, after the bubble is replaced or the app restarts.
    expect(attachmentDisplayName('attachments/notes-2.txt')).toBe('notes.txt')
    expect(attachmentDisplayName('attachments/unknown-2.txt')).toBe('unknown-2.txt')
  })

  test('the names survive a restart and keep the newest', () => {
    let saved: string | null = null
    const storage = { load: () => saved, save: (value: string) => { saved = value } }
    const names = new OriginalFileNames(2)
    names.use(storage)
    names.remember(['a-2.txt'], 'a.txt')
    names.remember(['b-2.txt', '/abs/b-2.txt'], 'b.txt')
    const restarted = new OriginalFileNames(2)
    restarted.use(storage)
    expect([restarted.name('a-2.txt'), restarted.name('b-2.txt'), restarted.name('/abs/b-2.txt')]).toEqual([undefined, 'b.txt', 'b.txt'])
  })

  test('a send with attachments mid-reply goes to Hermes\'s queue, not the app\'s', async () => {
    const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
    const { chat, composer } = await openStored(server)
    composer.setDraft('first')
    await composer.submit()
    server.event('message.start', chat.sessionID, 1)
    await eventually(() => chat.get().isRunning)
    await composer.attachments.attachFile(new TextEncoder().encode('%PDF'), 'report.pdf', 'application/pdf')
    composer.setDraft('and this')
    await composer.submit()
    expect(composer.queue.held).toHaveLength(0)
    expect(server.calls('prompt.submit').at(-1)?.text).toBe('@file:attachments/report.pdf\n\nand this')
  })

  test('a picked PNG becomes an image card, not a file', async () => {
    const server = new PagedServer()
    const { composer } = await openStored(server)
    await composer.attachments.attachFile(new Uint8Array([1, 2, 3]), 'pic.png')
    expect(composer.attachments.get().images).toHaveLength(1)
    expect(server.calls('file.attach')).toHaveLength(0)
  })

  test('removing a card takes its image back off the queue', async () => {
    const server = new PagedServer()
    const { composer } = await openStored(server)
    const image = png()
    composer.attachments.attachImage(image)
    await composer.attachments.uploadsSettled()
    composer.attachments.remove(image.id)
    await eventually(() => server.calls('image.detach').length === 1)
    expect(server.calls('image.detach')[0]?.path).toMatch(/shot\.png$/)
  })

  test('a failed submit detaches the images and gives back the cards and the text', async () => {
    const server = new PagedServer()
    const { chat, composer } = await openStored(server)
    composer.attachments.attachImage(png())
    await composer.attachments.uploadsSettled()
    server.errors.set('prompt.submit', { code: 5000, message: 'boom' })
    composer.setDraft('look')
    await composer.submit()
    expect(server.calls('image.detach')).toHaveLength(1)
    expect(composer.attachments.get().images).toHaveLength(1)
    expect(composer.draft).toBe('look')
    // The retry uploads the image again.
    server.errors.clear()
    await composer.submit()
    expect(server.calls('image.attach_bytes')).toHaveLength(2)
    expect(texts(chat).filter((line) => line === 'user:look').length).toBeGreaterThanOrEqual(1)
  })

  test('a failed upload is marked on its card, and the send uploads it again', async () => {
    const server = new PagedServer()
    const { composer } = await openStored(server)
    server.errors.set('image.attach_bytes', { code: 4016, message: 'unsupported' })
    const image = png()
    composer.attachments.attachImage(image)
    await composer.attachments.uploadsSettled()
    expect(composer.attachments.get().failedImageUploads[image.id]).toMatch(/Couldn't attach shot\.png: unsupported/)
    server.errors.clear()
    await composer.submit()
    expect(server.calls('image.attach_bytes')).toHaveLength(2)
    expect(server.calls('prompt.submit')).toHaveLength(1)
  })

  test('at most ten images per message', async () => {
    const server = new PagedServer()
    const { composer } = await openStored(server)
    for (let index = 0; index < 10; index += 1) expect(composer.attachments.attachImage(png(`${index}.png`))).toBe(true)
    expect(composer.attachments.attachImage(png('11.png'))).toBe(false)
    expect(composer.get().error).toBe('At most 10 images per message.')
  })
})

describe('stranded images', () => {
  test('a send waits for its session\'s stranded images to be detached', async () => {
    const server = new PagedServer()
    const { connection, chat, composer } = await openStored(server)
    connection.chats.strandedImages.strand([{ sessionID: chat.sessionID, path: '/img/old.png', profile: 'default' }])
    composer.setDraft('hi')
    await composer.submit()
    expect(server.calls('image.detach')).toEqual([{ session_id: chat.sessionID, path: '/img/old.png', profile: 'default' }])
    expect(server.calls('prompt.submit')).toHaveLength(1)
    expect(connection.chats.strandedImages.paths(chat.sessionID)).toEqual([])
  })

  test('a detach that gets no answer keeps the send from going out', async () => {
    const server = new PagedServer()
    const { connection, chat, composer } = await openStored(server)
    const stranded = connection.chats.strandedImages
    stranded.strand([{ sessionID: chat.sessionID, path: '/img/old.png' }])
    // An answer of any kind settles a path; only no answer at all keeps it.
    const client = { call: () => Promise.reject(new Error('socket dropped')) }
    expect(await stranded.clear(chat.sessionID, client as never)).toBe(false)
    expect(stranded.paths(chat.sessionID)).toEqual(['/img/old.png'])
    composer.setDraft('after the outage')
    await composer.submit()
    expect(server.calls('prompt.submit')).toHaveLength(1)
  })

  test('the list keeps at most fifty, dropping the oldest', () => {
    const stranded = new StrandedImages()
    stranded.strand(Array.from({ length: 55 }, (_, index) => ({ sessionID: 's', path: `/p${index}` })))
    expect(stranded.paths('s')).toHaveLength(50)
    expect(stranded.paths('s')[0]).toBe('/p5')
  })
})
