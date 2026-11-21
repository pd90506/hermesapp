import { DashboardConnector } from '../connector.ts'
import { DashboardError } from '../dashboard.ts'
import { requestStatus, type DashboardAPI } from '../dashboard-api.ts'
import { describeError } from '../describe.ts'
import type { HttpRequest } from '../http.ts'
import { isImagePath } from './files.ts'
import { isRelativePath } from './directives.ts'

declare function setTimeout(handler: () => void, ms?: number): unknown

/**
 * Reads a stored image (HermesKit's `DashboardConnector.imageData`, docs/protocol.md
 * §10.3): `GET /api/media?path=` → `{data_url}`, which serves only the dashboard's own
 * `HERMES_HOME`; an upload to another profile's session lives under that profile's home
 * and answers 403, so those are read as Desktop's remote mode reads them,
 * `GET /api/fs/read-data-url?path=&profile=` → `{dataUrl}`. The fallback is only for
 * paths with an image extension.
 */
export async function imageDataURL(api: DashboardAPI, path: string, profile: string | undefined): Promise<string> {
  try {
    const answer = await api.send('GET', '/api/media', { query: [['path', path]], timeoutMs: 60_000 }) as { data_url?: unknown } | null
    if (typeof answer?.data_url === 'string' && answer.data_url.startsWith('data:')) return answer.data_url
  } catch (error) {
    const status = requestStatus(error)
    if (status !== 403 && status !== 404) throw error
  }
  if (!isImagePath(path)) throw new DashboardError('http', 404, 'not an image')
  const query: Array<[string, string]> = [['path', path]]
  if (profile !== undefined) query.push(['profile', profile])
  const answer = await api.send('GET', '/api/fs/read-data-url', { query, timeoutMs: 60_000 }) as { dataUrl?: unknown } | null
  if (typeof answer?.dataUrl === 'string' && answer.dataUrl.startsWith('data:')) return answer.dataUrl
  throw new DashboardError('http', 404, 'no image data')
}

/** `/api/fs/read-text`'s cap on what it returns (`_FS_TEXT_PREVIEW_MAX_BYTES`): a longer file is cut. */
export interface GatewayTextFile {
  text: string
  binary: boolean
  truncated: boolean
}

/**
 * Reads a text file on the gateway, as Desktop's remote mode reads a `::preview` page
 * (`readDesktopFileText`): `GET /api/fs/read-text?path=&profile=&session_id=` →
 * `{text, binary, truncated}` (`hermes_cli/web_routers/files.py`). `storedSessionID` is sent
 * only for a relative path, which the gateway resolves against that chat's folder.
 */
export async function readGatewayText(api: DashboardAPI, path: string, profile: string | undefined,
  storedSessionID: string | undefined): Promise<GatewayTextFile> {
  const query: Array<[string, string]> = [['path', path]]
  if (profile !== undefined) query.push(['profile', profile])
  if (storedSessionID !== undefined && isRelativePath(path)) query.push(['session_id', storedSessionID])
  const answer = await api.send('GET', '/api/fs/read-text', { query, timeoutMs: 60_000 }) as
    { text?: unknown; binary?: unknown; truncated?: unknown } | null
  if (typeof answer?.text !== 'string') throw new DashboardError('http', 404, 'no text')
  return { text: answer.text, binary: answer.binary === true, truncated: answer.truncated === true }
}

/**
 * A web image the gateway fetches for the app, as Desktop retries one this computer could not
 * load (`GET /api/media/proxy?url=` → `{data_url}`, only the gateway's allowlisted image hosts).
 */
export async function proxiedImageDataURL(api: DashboardAPI, url: string): Promise<string> {
  const answer = await api.send('GET', '/api/media/proxy', { query: [['url', url]], timeoutMs: 60_000 }) as { data_url?: unknown } | null
  if (typeof answer?.data_url === 'string' && answer.data_url.startsWith('data:image/')) return answer.data_url
  throw new DashboardError('http', 404, 'no image data')
}

/** Runs at most `limit` tasks at a time (HermesKit's `AsyncLimiter`). */
export class AsyncLimiter {
  private running = 0
  private readonly waiting: Array<() => void> = []
  constructor(readonly limit: number) {}

  async run<T>(task: () => Promise<T>): Promise<T> {
    if (this.running >= this.limit) await new Promise<void>((resolve) => this.waiting.push(resolve))
    this.running += 1
    try {
      return await task()
    } finally {
      this.running -= 1
      this.waiting.shift()?.()
    }
  }
}

export type ThumbnailState =
  | { phase: 'loading' }
  | { phase: 'loaded'; url: string }
  /** 404 gone, 413 too large, offline: a placeholder with the name; retried after `retryAfterMs`. */
  | { phase: 'failed'; message: string; at: number }

/**
 * The transcript's image thumbnails, by server, profile and path (HermesKit's
 * `ThumbnailStore`): at most 3 read at a time, at most 300 kept (or 64 MB of data URLs),
 * failures retried after a minute. `shrink` downsamples a read image (to 480 px in the
 * app); a sent image's thumbnail is put in under its upload's path, so its stored row
 * shows without a download.
 */
export class ThumbnailCache {
  static readonly maxEntries = 300
  static readonly maxBytes = 64 * 1024 * 1024
  static readonly retryAfterMs = 60_000
  private readonly entries = new Map<string, ThumbnailState>()
  private readonly loads = new Map<string, Promise<ThumbnailState>>()
  private readonly listeners = new Set<() => void>()
  private readonly limiter = new AsyncLimiter(3)
  private bytes = 0

  constructor(private readonly shrink: (dataURL: string) => Promise<string> = async (url) => url,
    private readonly now: () => number = () => Date.now()) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  static key(server: string, profile: string | undefined, path: string): string {
    return `${server}\u0000${profile ?? ''}\u0000${path}`
  }

  state(key: string): ThumbnailState | undefined {
    const entry = this.entries.get(key)
    if (entry?.phase === 'loaded') {
      // Most recently used last.
      this.entries.delete(key)
      this.entries.set(key, entry)
    }
    return entry
  }

  /** Puts an image this device already has (a sent attachment) under its gateway path. */
  put(key: string, url: string): void {
    this.store(key, { phase: 'loaded', url })
  }

  /** Reads the image unless it is loaded, loading, or failed less than a minute ago. */
  load(key: string, read: () => Promise<string>): Promise<ThumbnailState> {
    const entry = this.entries.get(key)
    if (entry?.phase === 'loaded') return Promise.resolve(entry)
    if (entry?.phase === 'failed' && this.now() - entry.at < ThumbnailCache.retryAfterMs) return Promise.resolve(entry)
    const running = this.loads.get(key)
    if (running) return running
    this.store(key, { phase: 'loading' })
    const load = this.limiter.run(async (): Promise<ThumbnailState> => {
      try {
        return { phase: 'loaded', url: await this.shrink(await read()) }
      } catch (error) {
        return { phase: 'failed', message: describeError(error), at: this.now() }
      }
    }).then((state) => {
      this.loads.delete(key)
      this.store(key, state)
      return state
    })
    this.loads.set(key, load)
    return load
  }

  private store(key: string, state: ThumbnailState): void {
    const old = this.entries.get(key)
    if (old?.phase === 'loaded') this.bytes -= old.url.length
    this.entries.delete(key)
    this.entries.set(key, state)
    if (state.phase === 'loaded') this.bytes += state.url.length
    for (const [other, entry] of this.entries) {
      if (this.entries.size <= ThumbnailCache.maxEntries && this.bytes <= ThumbnailCache.maxBytes) break
      if (other === key || entry.phase === 'loading') continue
      if (entry.phase === 'loaded') this.bytes -= entry.url.length
      this.entries.delete(other)
    }
    for (const listener of [...this.listeners]) listener()
  }
}

/**
 * The request that downloads a file Hermes delivered (`GET /api/fs/download?path=&profile=
 * &session_id=`, docs/protocol.md §10.10), authenticated like the other REST calls: a token
 * as `Authorization: Bearer`, or the cookie session the main process keeps. `session_id`
 * is a stored key, sent only for relative paths (a chat not stored yet answers 404).
 */
export async function fileDownloadRequest(connector: DashboardConnector, path: string, profile: string | undefined,
  storedSessionID: string | undefined): Promise<HttpRequest> {
  const query: Array<[string, string]> = [['path', path]]
  if (profile !== undefined) query.push(['profile', profile])
  const relative = !path.startsWith('/') && !path.startsWith('~') && !/^[A-Za-z]:[\\/]/.test(path)
  if (relative && storedSessionID !== undefined) query.push(['session_id', storedSessionID])
  const headers: Record<string, string> = {}
  const credential = connector.credential
  if (credential.kind === 'bearer') headers.Authorization = `Bearer ${credential.accessToken}`
  if (credential.kind === 'sessionToken') headers.Authorization = `Bearer ${credential.token}`
  if (credential.kind === 'native') headers.Authorization = `Bearer ${(await credential.session.accessToken(connector.dashboard)).token}`
  return { method: 'GET', url: connector.endpoint.urlFor('/api/fs/download', query), headers, timeoutMs: 300_000 }
}

/** What the app's downloader answers: the saved file, or the refusal's status and body. */
export type DownloadResult = { ok: true; path: string } | { ok: false; status: number; body: string }

/**
 * Downloads a delivered file with `download` (the main process streams it to disk). A
 * password sign-in whose cookie expired signs in again once, as `dashboardAPI` does.
 */
export async function downloadDeliveredFile(connector: DashboardConnector, path: string, profile: string | undefined,
  storedSessionID: string | undefined, download: (request: HttpRequest) => Promise<DownloadResult>): Promise<string> {
  let result = await download(await fileDownloadRequest(connector, path, profile, storedSessionID))
  const credential = connector.credential
  if (!result.ok && result.status === 401 && credential.kind === 'password') {
    await connector.dashboard.passwordLogin(credential.provider, credential.username, credential.password)
    result = await download(await fileDownloadRequest(connector, path, profile, storedSessionID))
  }
  if (result.ok) return result.path
  let detail = ''
  try {
    const parsed = JSON.parse(result.body) as { detail?: unknown }
    if (typeof parsed.detail === 'string') detail = parsed.detail
  } catch {}
  throw new DashboardError('http', result.status, detail || `HTTP ${result.status}`)
}
