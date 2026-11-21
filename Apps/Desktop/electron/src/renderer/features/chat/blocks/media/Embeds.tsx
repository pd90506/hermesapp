import { useEffect, useMemo, useRef, useState } from 'react'
import {
  proxiedImageDataURL, previewTarget, readGatewayText, type ChatSession, type GatewayConnection, type TranscriptDirective,
} from '@talaria/hermes-core'
import { useConnection, useSnapshot } from '../../../../app/hooks.ts'
import { ImageViewer } from './MediaViews.tsx'
import {
  currentWidgetTheme, evaluateIntent, initialWidgetHeight, intentAck, reportedHeight, widgetDefaultHeight, widgetDocument,
  widgetResizeTolerance, type IntentAck, type WidgetTheme,
} from './widget-frame.ts'
import styles from './Embeds.module.css'

/* ── Web images: `![alt](https://…)` ─────────────────────────────────────────────── */

const imageCacheLimit = 64
const images = new Map<string, Promise<string | null>>()

/** A web image as a data URL: fetched by the main process, else by the gateway's proxy (Desktop's retry). */
function webImage(connection: GatewayConnection, url: string): Promise<string | null> {
  let pending = images.get(url)
  if (!pending) {
    pending = (async () => {
      const direct = await window.talaria.embeds.remoteImage(url).catch(() => null)
      if (direct) return direct
      const api = connection.dashboardAPI
      return api ? proxiedImageDataURL(api, url).catch(() => null) : null
    })()
    images.set(url, pending)
    while (images.size > imageCacheLimit) images.delete(images.keys().next().value!)
    // A failure is not remembered: the next time the reply shows, it tries again.
    void pending.then((value) => { if (value === null && images.get(url) === pending) images.delete(url) })
  }
  return pending
}

/**
 * A web image in a reply, as Desktop draws `![alt](url)`: at its own size, never larger than
 * the frame; a click shows it over the window. Until it loads, and when it can't, its name.
 */
export function WebImage({ url, alt }: { url: string; alt: string }) {
  const connection = useConnection()
  const [state, setState] = useState<{ url: string; data: string | null } | undefined>()
  const [viewing, setViewing] = useState(false)
  useEffect(() => {
    let live = true
    void webImage(connection, url).then((data) => { if (live) setState({ url, data }) })
    return () => { live = false }
  }, [connection, url])
  const name = alt || url.split(/[?#]/)[0]!.split('/').pop() || url
  const data = state?.url === url ? state.data : undefined
  if (data === null) {
    return (
      <span className={styles.imageFailed}>
        Couldn’t load {name}.{' '}
        <button type="button" className={styles.inlineButton} onClick={() => void window.talaria.links.open(url)}>Open in Browser</button>
      </span>
    )
  }
  if (data === undefined) return <span className={styles.imageLoading} aria-busy="true">Loading {name}…</span>
  return (
    <>
      <button type="button" className={styles.webImage} title={alt || url} aria-label={`View ${name}`} onClick={() => setViewing(true)}>
        <img src={data} alt={alt} draggable={false} />
      </button>
      {viewing && <ImageViewer connection={connection} name={name} preview={data} onClose={() => setViewing(false)} />}
    </>
  )
}

/* ── Widgets: `::preview{file="page.html"}` ─────────────────────────────────────── */

/** A directive the reply holds: `preview` draws its page in place; anything else draws nothing. */
export function DirectiveView({ directive, streaming, chat, fallback }: {
  directive: TranscriptDirective
  streaming: boolean
  chat: ChatSession
  /** How a file that isn't a page shows: as a delivered file's card. */
  fallback: (path: string) => React.ReactNode
}) {
  if (directive.name !== 'preview') return null
  const target = previewTarget(directive.attrs.file)
  if (!target) return null
  if (target.kind === 'url') {
    return (
      <button type="button" className={styles.inlineButton} onClick={() => void window.talaria.links.open(target.url)}>
        {target.url}
      </button>
    )
  }
  if (target.kind === 'file') return <>{fallback(target.path)}</>
  return <WidgetFrame path={target.path} initialHeight={initialWidgetHeight(directive.attrs.height)} streaming={streaming}
    chat={chat} fallback={fallback} />
}

/** The live theme, read again when the app's colour theme, text size or light/dark changes. */
function useWidgetTheme(): WidgetTheme {
  const [theme, setTheme] = useState(currentWidgetTheme)
  useEffect(() => {
    let frame = 0
    const update = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => setTheme((old) => {
        const next = currentWidgetTheme()
        return JSON.stringify(next) === JSON.stringify(old) ? old : next
      }))
    }
    const observer = new MutationObserver(update)
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'style', 'class'] })
    const scheme = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : undefined
    scheme?.addEventListener('change', update)
    return () => {
      cancelAnimationFrame(frame)
      observer.disconnect()
      scheme?.removeEventListener('change', update)
    }
  }, [])
  return theme
}

/**
 * An HTML page the agent wrote, live in the reply (Desktop's `InlineHtmlFrame`): a frame with
 * an opaque origin (`sandbox="allow-scripts"`), so its scripts run but it reaches nothing of
 * the app. The page is read once the reply has finished (mid-stream it may be half-written)
 * and again after each later turn, so a widget the agent updates shows the new page. Its
 * height follows its content; `hermes.send` goes to this chat as a hidden prompt.
 */
function WidgetFrame({ path, initialHeight, streaming, chat, fallback }: {
  path: string
  initialHeight: number | undefined
  streaming: boolean
  chat: ChatSession
  fallback: (path: string) => React.ReactNode
}) {
  const connection = useConnection()
  const view = useSnapshot(chat)
  const theme = useWidgetTheme()
  const token = useMemo(() => crypto.randomUUID(), [])
  const [html, setHtml] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const [measured, setMeasured] = useState<number>()
  const [address, setAddress] = useState<string>()
  const frame = useRef<HTMLIFrameElement>(null)

  // Counts the turns that finished since this mounted: each one reads the page again.
  const [turns, setTurns] = useState(0)
  const wasRunning = useRef(view.isRunning)
  useEffect(() => {
    if (wasRunning.current && !view.isRunning) setTurns((count) => count + 1)
    wasRunning.current = view.isRunning
  }, [view.isRunning])

  useEffect(() => {
    if (streaming) return
    const api = connection.dashboardAPI
    if (!api) {
      setFailed(true)
      return
    }
    let live = true
    readGatewayText(api, path, view.profile, view.storedSessionID).then((file) => {
      if (!live) return
      if (file.binary || file.truncated || file.text.trim() === '') setFailed(true)
      else setHtml((old) => (old === file.text ? old : file.text))
    }, () => { if (live) setFailed(true) })
    return () => { live = false }
  }, [connection, path, view.profile, view.storedSessionID, streaming, turns])

  const page = useMemo(() => (html === null ? null : widgetDocument(html, token, theme)), [html, token, theme])

  useEffect(() => {
    if (page === null) return
    let live = true
    let hosted: string | undefined
    void window.talaria.embeds.hostWidget(page).then((url) => {
      hosted = url
      if (live) setAddress(url)
      else window.talaria.embeds.releaseWidget(url)
    }, () => { if (live) setFailed(true) })
    return () => {
      live = false
      if (hosted) window.talaria.embeds.releaseWidget(hosted)
    }
  }, [page])

  useEffect(() => {
    let lastIntentAt = 0
    const onMessage = (event: MessageEvent) => {
      if (event.source !== frame.current?.contentWindow) return
      const decision = evaluateIntent(event.data, token, Date.now(), lastIntentAt)
      if (decision) {
        const reply = (ack: IntentAck) => {
          if (decision.id !== null) (event.source as Window).postMessage(intentAck(token, decision.id, ack), '*')
        }
        if (decision.kind === 'reject') {
          reply(decision.ack)
          return
        }
        lastIntentAt = Date.now()
        void chat.sendHidden(decision.prompt).then((ok) => reply(ok ? { ok: true } : { ok: false, error: 'undelivered' }))
        return
      }
      const height = reportedHeight(event.data, token)
      if (height === undefined) return
      setMeasured((old) => (Math.abs(height - (old ?? initialHeight ?? widgetDefaultHeight)) > widgetResizeTolerance ? height : old))
    }
    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [chat, token, initialHeight])

  if (failed && html === null) return <>{fallback(path)}</>
  const height = measured ?? initialHeight ?? widgetDefaultHeight
  return (
    <div className={styles.widget} style={{ height }}>
      {address
        ? <iframe ref={frame} className={styles.widgetFrame} src={address} sandbox="allow-scripts" title={path}
            referrerPolicy="no-referrer" style={{ colorScheme: theme.colorScheme }} />
        : <div className={styles.widgetLoading} aria-busy="true" />}
    </div>
  )
}
