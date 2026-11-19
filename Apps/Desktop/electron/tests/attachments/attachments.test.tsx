import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { Observable } from '@talaria/hermes-core'
import { ModelContext } from '../../src/renderer/app/hooks.ts'
import type { AppModel } from '../../src/renderer/app/model.ts'
import { ChatPane } from '../../src/renderer/features/chat/ChatPane.tsx'
import { PagedServer, completePayload, eventually, rows } from '../../../../../Packages/hermes-core/tests/support/paged-server.ts'

class NoResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
const sizes = ['offsetHeight', 'offsetWidth', 'clientHeight', 'clientWidth'] as const
const picked: Array<{ path: string; name: string; size: number; bytes: Uint8Array }> = []
beforeAll(() => {
  Object.assign(window, { ResizeObserver: NoResizeObserver })
  for (const name of sizes) {
    Object.defineProperty(HTMLElement.prototype, name, { configurable: true, get: () => name.endsWith('Width') ? 800 : 100 })
  }
  let next = 0
  Object.assign(URL, { createObjectURL: () => `blob:test-${++next}`, revokeObjectURL: () => {} })
  Object.assign(window, {
    talaria: {
      files: {
        pathFor: () => '',
        pick: async () => picked.map(({ path, name, size }) => ({ path, name, size })),
        read: async (path: string) => picked.find((file) => file.path === path)!.bytes,
        convertImage: async () => null,
      },
    },
  })
})
afterEach(cleanup)

async function openChat(server: PagedServer) {
  server.store.append(rows(1, 2))
  const connection = await server.connect()
  const model = Object.assign(new Observable({}), { connection }) as unknown as AppModel
  render(<ModelContext.Provider value={model}><ChatPane /></ModelContext.Provider>)
  await act(async () => { await connection.chats.openBotChat('coder') })
  await eventually(() => screen.queryByText('row 2') !== null)
  return connection
}

const file = (name: string, type: string, text = 'data') => new File([text], name, { type })

describe('attachments', () => {
  it('a pasted image becomes a card, uploads at once, and goes with Send', async () => {
    const server = new PagedServer()
    await openChat(server)
    const text = screen.getByLabelText('Message')
    fireEvent.paste(text, { clipboardData: { files: [file('Screenshot.png', 'image/png')], getData: () => '' } })
    expect(await eventually(() => screen.queryByLabelText('Preview Screenshot.png') !== null)).toBe(true)
    expect(await eventually(() => server.calls('image.attach_bytes').length === 1)).toBe(true)
    expect(server.calls('image.attach_bytes')[0]?.filename).toBe('Screenshot.png')
    await eventually(() => !(screen.getByLabelText('Send') as HTMLButtonElement).disabled)
    fireEvent.click(screen.getByLabelText('Send'))
    expect(await eventually(() => server.calls('prompt.submit').length === 1)).toBe(true)
    expect(screen.queryByLabelText('Preview Screenshot.png')).toBeNull()
    expect(await eventually(() => screen.queryByLabelText('View Screenshot.png') !== null || screen.queryAllByRole('button', { name: /^View / }).length > 0)).toBe(true)
  })

  it('a paste of real text with a picture beside it stays text', async () => {
    const server = new PagedServer()
    await openChat(server)
    fireEvent.paste(screen.getByLabelText('Message'), {
      clipboardData: { files: [file('image.png', 'image/png')], getData: () => 'Q1\t10\nQ2\t12' },
    })
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(server.calls('image.attach_bytes')).toHaveLength(0)
  })

  it('a dropped PDF uploads as a file and goes as a reference', async () => {
    const server = new PagedServer()
    await openChat(server)
    const drop = new Event('drop', { bubbles: true, cancelable: true })
    Object.assign(drop, { dataTransfer: { types: ['Files'], files: [file('report.pdf', 'application/pdf', '%PDF')] } })
    act(() => { window.dispatchEvent(drop) })
    expect(await eventually(() => screen.queryByLabelText('report.pdf') !== null)).toBe(true)
    expect(server.calls('file.attach')[0]).toMatchObject({ name: 'report.pdf', data_url: 'data:application/pdf;base64,JVBERg==' })
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'summarize' } })
    fireEvent.keyDown(screen.getByLabelText('Message'), { key: 'Enter' })
    expect(await eventually(() => server.calls('prompt.submit').length === 1)).toBe(true)
    expect(server.calls('prompt.submit')[0]?.text).toBe('@file:attachments/report.pdf\n\nsummarize')
    expect(await eventually(() => screen.queryByLabelText('Open report.pdf') !== null)).toBe(true)
  })

  it('Attach files… adds what the open dialog picked', async () => {
    const server = new PagedServer()
    await openChat(server)
    picked.splice(0, picked.length, { path: '/Users/u/notes.txt', name: 'notes.txt', size: 5, bytes: new TextEncoder().encode('hello') })
    fireEvent.click(screen.getByLabelText('Attach Files'))
    expect(await eventually(() => server.calls('file.attach').length === 1)).toBe(true)
    expect(server.calls('file.attach')[0]?.name).toBe('notes.txt')
    expect(await eventually(() => screen.queryByLabelText('Remove notes.txt') !== null)).toBe(true)
    fireEvent.click(screen.getByLabelText('Remove notes.txt'))
    expect(screen.queryByLabelText('notes.txt')).toBeNull()
  })

  it('a reply\'s MEDIA: tag shows as a file card where it was', async () => {
    const server = new PagedServer()
    const connection = await openChat(server)
    const chat = connection.chats.active!
    chat.coalescesStreamedText = false
    const sid = chat.sessionID
    const reply = 'Here is the report.\n\nMEDIA:/tmp/out/report.pdf\n\nAnything else?'
    act(() => {
      server.store.append([{ id: server.store.nextID(), role: 'assistant', content: reply, timestamp: 1_700_000_100 }])
      server.event('message.start', sid, 1)
      server.event('message.delta', sid, 2, { text: reply })
      server.event('message.complete', sid, 3, completePayload(reply, [3]))
    })
    expect(await eventually(() => screen.queryByLabelText('Open report.pdf') !== null)).toBe(true)
    expect(screen.queryByText(/MEDIA:/)).toBeNull()
    expect(screen.queryAllByText('Anything else?').length).toBeGreaterThan(0)
  })
})
