import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { Observable, type GatewayConnection } from '@talaria/hermes-core'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel } from '../src/renderer/app/model.ts'
import { ChatPane } from '../src/renderer/features/chat/ChatPane.tsx'
import {
  evaluateIntent, initialWidgetHeight, reportedHeight, widgetDocument, type WidgetTheme,
} from '../src/renderer/features/chat/blocks/media/widget-frame.ts'
import { PagedServer, completePayload, eventually, rows } from '../../../../Packages/hermes-core/tests/support/paged-server.ts'
import { FakeDashboardAPI } from '../../../../Packages/hermes-core/tests/support/fake-dashboard-api.ts'
import replyEmbeds from '../../../../Packages/fixtures/reply-embeds.json' with { type: 'json' }

class NoResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
const sizes = ['offsetHeight', 'offsetWidth', 'clientHeight', 'clientWidth'] as const
const hosted: string[] = []
const released: string[] = []
const fetched: string[] = []
beforeAll(() => {
  Object.assign(window, { ResizeObserver: NoResizeObserver })
  for (const name of sizes) {
    Object.defineProperty(HTMLElement.prototype, name, { configurable: true, get: () => name.endsWith('Width') ? 800 : 100 })
  }
  Object.assign(window, {
    talaria: {
      links: { open: async () => true },
      embeds: {
        hostWidget: async (html: string) => {
          hosted.push(html)
          return `talaria-widget://page/${hosted.length}`
        },
        releaseWidget: (url: string) => { released.push(url) },
        remoteImage: async (url: string) => {
          fetched.push(url)
          return url.includes('broken') ? null : 'data:image/png;base64,AA=='
        },
      },
    },
  })
})
afterEach(cleanup)

const theme = { vars: { '--foreground': '#111' }, font: 'Segoe UI', colorScheme: 'light' as const }

// The cases HermesKit's WidgetFrame checks too (Packages/fixtures/reply-embeds.json).
describe('reply-embeds.json', () => {
  it.each(replyEmbeds.widgetDocuments)('the page for token $token', (item) => {
    expect(widgetDocument(item.html, item.token, item.theme as WidgetTheme)).toBe(item.document)
  })
  it.each(replyEmbeds.intents)('intent at $now', (item) => {
    expect(evaluateIntent(item.data, item.token, item.now, item.lastAcceptedAt)).toEqual(item.decision)
  })
  it.each(replyEmbeds.reportedHeights)('reported height', (item) => {
    expect(reportedHeight(item.data, item.token) ?? null).toBe(item.height)
  })
  it.each(replyEmbeds.initialHeights)('initial height $raw', (item) => {
    expect(initialWidgetHeight(item.raw) ?? null).toBe(item.height)
  })
})

describe('widget page', () => {
  it('puts the theme first, after the doctype, and the scripts before </body>', () => {
    const page = widgetDocument('<!DOCTYPE html><html><body><p>hi</p></body></html>', 't1', theme)
    expect(page.startsWith('<!DOCTYPE html><meta charset="utf-8"><style>:root{color-scheme:light;--foreground:#111}')).toBe(true)
    expect(page.indexOf('hermes-inline-preview-size')).toBeLessThan(page.indexOf('</body>'))
    expect(page).toContain('window.hermes={send:send')
    expect(widgetDocument('<p>bare</p>', 't', theme).startsWith('<!doctype html>')).toBe(true)
  })

  it('trusts only its own token, and refuses long or hurried prompts', () => {
    const message = (prompt: unknown, token = 'tok') => ({ type: 'hermes-inline-preview-intent', token, id: 1, prompt })
    expect(evaluateIntent(message('refresh', 'other'), 'tok', 5000, 0)).toBeNull()
    expect(evaluateIntent(message('  refresh '), 'tok', 5000, 0)).toEqual({ kind: 'accept', id: 1, prompt: 'refresh' })
    expect(evaluateIntent(message('x'.repeat(501)), 'tok', 5000, 0)).toMatchObject({ kind: 'reject', ack: { error: 'too_long' } })
    expect(evaluateIntent(message('again'), 'tok', 5400, 5000)).toMatchObject({ kind: 'reject', ack: { error: 'throttled', retryAfterMs: 600 } })
    expect(evaluateIntent(message(''), 'tok', 5000, 0)).toMatchObject({ kind: 'reject', ack: { error: 'invalid' } })
  })

  it('keeps heights inside the band', () => {
    expect(reportedHeight({ type: 'hermes-inline-preview-size', token: 't', height: 40 }, 't')).toBe(120)
    expect(reportedHeight({ type: 'hermes-inline-preview-size', token: 't', height: 5000 }, 't')).toBe(1200)
    expect(reportedHeight({ type: 'hermes-inline-preview-size', token: 'x', height: 300 }, 't')).toBeUndefined()
    expect(initialWidgetHeight('480')).toBe(480)
    expect(initialWidgetHeight('tall')).toBeUndefined()
  })
})

async function openChat(server: PagedServer, api?: FakeDashboardAPI): Promise<GatewayConnection> {
  server.store.append(rows(1, 2))
  const connection = await server.connect()
  if (api) Object.defineProperty(connection, 'dashboardAPI', { get: () => api })
  const model = Object.assign(new Observable({}), { connection }) as unknown as AppModel
  render(<ModelContext.Provider value={model}><ChatPane /></ModelContext.Provider>)
  await act(async () => { await connection.chats.openBotChat('coder') })
  await eventually(() => screen.queryByText('row 2') !== null)
  return connection
}

function reply(server: PagedServer, connection: GatewayConnection, text: string): void {
  const chat = connection.chats.active!
  chat.coalescesStreamedText = false
  const sid = chat.sessionID
  act(() => {
    server.store.append([{ id: server.store.nextID(), role: 'assistant', content: text, timestamp: 1_700_000_100 }])
    server.event('message.start', sid, 1)
    server.event('message.delta', sid, 2, { text })
    server.event('message.complete', sid, 3, completePayload(text, [3]))
  })
}

describe('embeds in replies', () => {
  it('a web image shows in place; one that cannot load says so', async () => {
    const server = new PagedServer()
    const connection = await openChat(server)
    reply(server, connection, 'Look:\n\n![A cat](https://cdn.example.com/cat.png)\n\n![x](https://cdn.example.com/broken.png)')
    expect(await eventually(() => screen.queryByRole('img', { name: 'A cat' }) !== null)).toBe(true)
    expect((screen.getByRole('img', { name: 'A cat' }) as HTMLImageElement).src).toBe('data:image/png;base64,AA==')
    expect(fetched).toContain('https://cdn.example.com/cat.png')
    expect(await eventually(() => screen.queryByText(/Couldn’t load x/) !== null)).toBe(true)
  })

  it('a ::preview page runs in a sandboxed frame, and its prompts go hidden to this chat', async () => {
    const server = new PagedServer()
    const api = new FakeDashboardAPI({
      'GET /api/fs/read-text': { text: '<html><body><button data-hermes-send="refresh">Refresh</button></body></html>', binary: false, truncated: false },
    })
    const connection = await openChat(server, api)
    reply(server, connection, 'Here it is.\n\n::preview{file="widget.html"}')
    expect(await eventually(() => document.querySelector('iframe') !== null)).toBe(true)
    const frame = document.querySelector('iframe')!
    expect(frame.getAttribute('sandbox')).toBe('allow-scripts')
    expect(frame.getAttribute('src')).toMatch(/^talaria-widget:\/\/page\//)
    expect(api.callsOf('GET')[0]?.query).toMatchObject({ path: 'widget.html' })
    const page = hosted[hosted.length - 1]!
    expect(page).toContain('data-hermes-send="refresh"')
    expect(screen.queryByText(/::preview/)).toBeNull()

    const token = /var t="([^"]+)"/.exec(page)![1]!
    act(() => {
      window.dispatchEvent(new MessageEvent('message', {
        data: { type: 'hermes-inline-preview-intent', token, id: 1, prompt: 'refresh' },
        source: frame.contentWindow,
      }))
    })
    expect(await eventually(() => server.calls('prompt.submit').length === 1)).toBe(true)
    expect(server.calls('prompt.submit')[0]).toMatchObject({ text: 'refresh', display_kind: 'hidden' })
    expect(screen.queryByText('refresh')).toBeNull()

    // A message from anything but the frame is ignored.
    act(() => {
      window.dispatchEvent(new MessageEvent('message', { data: { type: 'hermes-inline-preview-intent', token, id: 2, prompt: 'evil' } }))
    })
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(server.calls('prompt.submit')).toHaveLength(1)
  })

  it('a page the gateway cannot read shows as its file instead', async () => {
    const server = new PagedServer()
    const connection = await openChat(server, new FakeDashboardAPI())
    reply(server, connection, '::preview{file="/tmp/missing.html"}')
    expect(await eventually(() => screen.queryByLabelText('Open missing.html') !== null)).toBe(true)
  })
})
