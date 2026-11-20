import { useEffect, useSyncExternalStore } from 'react'
import {
  ThumbnailCache, describeError, downloadDeliveredFile, imageDataURL, type GatewayConnection, type ThumbnailState,
} from '@talaria/hermes-core'

/** Thumbnails are drawn at most this big on their long side (the Mac's 480 px). */
const thumbnailSide = 480

const caches = new WeakMap<GatewayConnection, ThumbnailCache>()

/** The connection's thumbnail cache: one per server, so paths never mix. */
export function thumbnailCache(connection: GatewayConnection): ThumbnailCache {
  let cache = caches.get(connection)
  if (!cache) {
    cache = new ThumbnailCache(shrink)
    caches.set(connection, cache)
  }
  return cache
}

/** A stored image's thumbnail, read when first shown (`/api/media`, then `read-data-url`). */
export function useThumbnail(connection: GatewayConnection, path: string | undefined, profile: string | undefined,
  localURL?: string): ThumbnailState | undefined {
  const cache = thumbnailCache(connection)
  const key = path === undefined ? undefined : ThumbnailCache.key('', profile, path)
  const state = useSyncExternalStore(cache.subscribe, () => (key === undefined ? undefined : cache.state(key)))
  useEffect(() => {
    if (key === undefined || path === undefined) return
    // An image sent from here: its stored row shows the same picture without a download.
    if (localURL) {
      if (cache.state(key)?.phase !== 'loaded') cache.put(key, localURL)
      return
    }
    const api = connection.dashboardAPI
    if (!api) return
    void cache.load(key, () => imageDataURL(api, path, profile))
  }, [cache, key, path, profile, localURL, connection])
  if (localURL) return { phase: 'loaded', url: localURL }
  return state
}

/** The full image, for the viewer. */
export async function fullImage(connection: GatewayConnection, path: string, profile: string | undefined): Promise<string> {
  const api = connection.dashboardAPI
  if (!api) throw new Error('Not connected to Hermes.')
  return imageDataURL(api, path, profile)
}

/** Draws a data URL at most `thumbnailSide` on its long side; SVG and failures stay as they are. */
async function shrink(url: string): Promise<string> {
  if (url.startsWith('data:image/svg')) return url
  try {
    const blob = await (await fetch(url)).blob()
    const bitmap = await createImageBitmap(blob)
    const longest = Math.max(bitmap.width, bitmap.height)
    if (longest <= thumbnailSide) {
      bitmap.close()
      return url
    }
    const scale = thumbnailSide / longest
    const canvas = new OffscreenCanvas(Math.round(bitmap.width * scale), Math.round(bitmap.height * scale))
    canvas.getContext('2d')?.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
    bitmap.close()
    const type = blob.type === 'image/jpeg' ? 'image/jpeg' : 'image/png'
    const out = await canvas.convertToBlob({ type, quality: 0.85 })
    return await new Promise<string>((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(String(reader.result))
      reader.onerror = () => reject(reader.error)
      reader.readAsDataURL(out)
    })
  } catch {
    return url
  }
}

/** Where a delivered or sent file is: its path, and the chat that names it. */
export interface GatewayFile {
  path: string
  name: string
  profile?: string
  /** The chat's stored key: a relative path resolves against its folder. */
  storedSessionID?: string
}

/** Downloads a file once (per address) into the app's cache; its local path. */
export async function downloadFile(connection: GatewayConnection, file: GatewayFile): Promise<string> {
  const connector = connection.dashboardConnector
  if (!connector) throw new Error('Downloads need a connection to the dashboard.')
  return downloadDeliveredFile(connector, file.path, file.profile, file.storedSessionID,
    (request) => window.talaria.files.download(request, file.name))
}

/** Click on a file: download it and open it in its default app. */
export async function openFile(connection: GatewayConnection, file: GatewayFile): Promise<void> {
  const local = await downloadFile(connection, file)
  if (!(await window.talaria.files.open(local))) throw new Error(`No app could open ${file.name}.`)
}

/** Save…: download it, then the system's save dialog. */
export async function saveFile(connection: GatewayConnection, file: GatewayFile): Promise<void> {
  await window.talaria.files.saveAs(await downloadFile(connection, file), file.name)
}

export function failureText(error: unknown): string {
  return describeError(error)
}
