import { BrowserWindow, ipcMain, protocol, session, shell, type WebContents } from 'electron'
import { randomUUID } from 'node:crypto'
import { IPC } from '../../shared/bridge.ts'

/**
 * Embeds in replies (`talaria.embeds`): web images and `::preview` widgets.
 *
 * - **Widgets** are served at `talaria-widget://page/<id>`, so each page carries its own
 *   content policy: a `srcdoc` frame would inherit the app's, which allows no inline script.
 *   The policy is the one Hermes gives its own previews (`hermes_cli/webapp_previews.py`,
 *   `_GUEST_SOURCES`): any library, image, font or fetch, because the isolation is the
 *   frame's opaque sandbox (`sandbox="allow-scripts"`, never `allow-same-origin`), not a
 *   source list. A page lives until its frame goes, at most `widgetLimit` at a time.
 * - A link clicked in a widget opens in the browser; the frame never navigates away.
 * - **Web images** are fetched here, as the renderer never touches the network, in a
 *   session of their own (no dashboard cookies), and handed back as data URLs.
 */

export const widgetScheme = 'talaria-widget'
const widgetLimit = 64
const widgetSizeLimit = 8 * 1024 * 1024
const imageSizeLimit = 20 * 1024 * 1024
const imageTimeoutMs = 30_000

const widgetPolicy = [
  "default-src 'none'",
  "script-src * data: blob: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'",
  "style-src * data: 'unsafe-inline'",
  'img-src * data: blob:',
  'font-src * data:',
  'media-src * data: blob:',
  'connect-src * data: blob:',
  'worker-src * data: blob:',
  'frame-src * data: blob: about:',
  "object-src 'none'",
  "form-action 'none'",
  'sandbox allow-scripts',
].join('; ')

/** Before the app is ready: the scheme is standard and secure, so `https:` assets are not mixed content. */
export function registerEmbedSchemes(): void {
  protocol.registerSchemesAsPrivileged([{ scheme: widgetScheme, privileges: { standard: true, secure: true } }])
}

export function registerEmbeds(): void {
  const pages = new Map<string, string>()

  protocol.handle(widgetScheme, (request) => {
    const url = new URL(request.url)
    const html = url.hostname === 'page' ? pages.get(url.pathname.slice(1)) : undefined
    if (html === undefined) return new Response('Not found', { status: 404 })
    return new Response(html, {
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Security-Policy': widgetPolicy,
        'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer',
        'X-Content-Type-Options': 'nosniff',
      },
    })
  })

  ipcMain.handle(IPC.embedsHostWidget, (event, html: unknown) => {
    if (!isAppWindow(event.sender)) throw new Error('Not the app window')
    if (typeof html !== 'string' || html.length > widgetSizeLimit) throw new Error('Not a page')
    while (pages.size >= widgetLimit) pages.delete(pages.keys().next().value!)
    const id = randomUUID()
    pages.set(id, html)
    return `${widgetScheme}://page/${id}`
  })

  ipcMain.on(IPC.embedsReleaseWidget, (_event, url: unknown) => {
    if (typeof url !== 'string') return
    try {
      const parsed = new URL(url)
      if (parsed.protocol === `${widgetScheme}:`) pages.delete(parsed.pathname.slice(1))
    } catch {}
  })

  const images = session.fromPartition('talaria-web-images')
  ipcMain.handle(IPC.embedsRemoteImage, async (event, url: unknown) => {
    if (!isAppWindow(event.sender) || typeof url !== 'string') return null
    return fetchImage(images, url)
  })
}

/** A widget's frame never navigates: a link it opens goes to the browser instead. */
export function keepWidgetsInPlace(contents: WebContents): void {
  contents.on('will-frame-navigate', (event) => {
    if (event.isMainFrame || event.url.startsWith(`${widgetScheme}:`) || event.url === 'about:blank') return
    event.preventDefault()
    if (/^https?:/i.test(event.url)) void shell.openExternal(event.url)
  })
}

function isAppWindow(contents: WebContents): boolean {
  return BrowserWindow.fromWebContents(contents) !== null
}

async function fetchImage(images: Electron.Session, raw: string): Promise<string | null> {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return null
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null
  const abort = new AbortController()
  const timer = setTimeout(() => abort.abort(), imageTimeoutMs)
  try {
    const response = await images.fetch(url.href, { signal: abort.signal, redirect: 'follow', credentials: 'omit' })
    if (!response.ok) return null
    const type = (response.headers.get('content-type') ?? '').split(';')[0]!.trim().toLowerCase()
    if (!type.startsWith('image/')) return null
    const declared = Number(response.headers.get('content-length') ?? '0')
    if (declared > imageSizeLimit) return null
    const reader = response.body?.getReader()
    if (!reader) return null
    const chunks: Uint8Array[] = []
    let size = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > imageSizeLimit) {
        void reader.cancel()
        return null
      }
      chunks.push(value)
    }
    return `data:${type};base64,${Buffer.concat(chunks).toString('base64')}`
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}
