import { BrowserWindow, app, dialog, ipcMain, nativeImage, shell } from 'electron'
import { createHash } from 'node:crypto'
import { createWriteStream } from 'node:fs'
import { execFile } from 'node:child_process'
import { copyFile, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, join, resolve, sep } from 'node:path'
import { promisify } from 'node:util'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { IPC, type BridgeHttpRequest, type ConvertedImage, type PickedFile } from '../../shared/bridge.ts'
import type { DashboardHttp } from '../dashboard-http.ts'

/** Files over this are listed by `pick` but never read: the composer refuses them anyway. */
const readLimit = 50 * 1024 * 1024

/**
 * E: the composer's files and the files Hermes delivers (`talaria.files`).
 * - Choose Files… is the system's open dialog; only the paths it returned can be read.
 * - HEIC and TIFF, which Chromium cannot decode, are re-encoded with `nativeImage` (the
 *   OS's decoder; macOS reads both, Windows neither).
 * - A delivered file is streamed from the dashboard into one folder in the app's cache,
 *   once per address, then opened in its default app or saved where the user picks. The
 *   folder is emptied when the app starts, so nothing piles up.
 */
export function registerFiles(http: DashboardHttp, window: () => BrowserWindow | undefined): void {
  const picked = new Set<string>()
  const downloads = join(app.getPath('userData'), 'Downloads cache')
  void rm(downloads, { recursive: true, force: true })
  const inDownloads = (path: string) => resolve(path).startsWith(resolve(downloads) + sep)

  ipcMain.handle(IPC.filesPick, async (): Promise<PickedFile[]> => {
    const owner = window()
    const options = { properties: ['openFile' as const, 'multiSelections' as const] }
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options)
    if (result.canceled) return []
    const files: PickedFile[] = []
    for (const path of result.filePaths) {
      try {
        const info = await stat(path)
        if (!info.isFile()) continue
        picked.add(path)
        files.push({ path, name: basename(path), size: info.size })
      } catch {}
    }
    return files
  })

  ipcMain.handle(IPC.filesRead, async (_event, path: unknown): Promise<Uint8Array> => {
    if (typeof path !== 'string' || !picked.has(path)) throw new Error('Not a picked file')
    picked.delete(path)
    if ((await stat(path)).size > readLimit) throw new Error('Too large')
    return new Uint8Array(await readFile(path))
  })

  ipcMain.handle(IPC.filesConvertImage, async (_event, bytes: unknown, options: { maxPixels?: number; format?: string }): Promise<ConvertedImage | null> => {
    if (!(bytes instanceof Uint8Array)) return null
    let image = nativeImage.createFromBuffer(Buffer.from(bytes))
    // nativeImage reads only PNG and JPEG from memory; on macOS `sips` (ImageIO) reads HEIC and TIFF.
    if (image.isEmpty() && process.platform === 'darwin') image = await decodeWithSips(bytes)
    if (image.isEmpty()) return null
    const size = image.getSize()
    const longest = Math.max(size.width, size.height)
    if (options.maxPixels && longest > options.maxPixels) {
      const scale = options.maxPixels / longest
      image = image.resize({ width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale)), quality: 'best' })
    }
    const out = options.format === 'png' ? image.toPNG() : image.toJPEG(88)
    const final = image.getSize()
    return { bytes: new Uint8Array(out), width: final.width, height: final.height }
  })

  const running = new Map<string, Promise<{ ok: true; path: string } | { ok: false; status: number; body: string }>>()
  ipcMain.handle(IPC.filesDownload, (_event, request: BridgeHttpRequest, name: unknown) => {
    const url = new URL(request.url)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('Only http(s) downloads')
    const key = createHash('sha256').update(request.url).digest('hex').slice(0, 24)
    const fileName = safeName(typeof name === 'string' ? name : 'download')
    const folder = join(downloads, key)
    const target = join(folder, fileName)
    const existing = running.get(key)
    if (existing) return existing
    const task = (async () => {
      try {
        if ((await stat(target)).isFile()) return { ok: true as const, path: target }
      } catch {}
      const headers: Record<string, string> = { ...request.headers }
      const cookie = http.cookieHeader(url)
      if (cookie) headers.Cookie = cookie
      const response = await fetch(url, { headers, redirect: 'manual', signal: AbortSignal.timeout(request.timeoutMs ?? 300_000) })
      if (response.status !== 200 || !response.body) {
        return { ok: false as const, status: response.status, body: (await response.text()).slice(0, 2000) }
      }
      await mkdir(folder, { recursive: true })
      const partial = `${target}.part`
      try {
        await pipeline(Readable.fromWeb(response.body as never), createWriteStream(partial))
        await rename(partial, target)
      } catch (error) {
        await rm(partial, { force: true })
        throw error
      }
      return { ok: true as const, path: target }
    })().finally(() => running.delete(key))
    running.set(key, task)
    return task
  })

  ipcMain.handle(IPC.filesOpen, async (_event, path: unknown) => {
    if (typeof path !== 'string' || !inDownloads(path)) return false
    return (await shell.openPath(path)) === ''
  })

  ipcMain.handle(IPC.filesSaveAs, async (_event, path: unknown, name: unknown) => {
    if (typeof path !== 'string' || !inDownloads(path)) return false
    const owner = window()
    const options = { defaultPath: join(app.getPath('downloads'), safeName(typeof name === 'string' ? name : basename(path))) }
    const result = owner ? await dialog.showSaveDialog(owner, options) : await dialog.showSaveDialog(options)
    if (result.canceled || !result.filePath) return false
    await copyFile(path, result.filePath)
    return true
  })
}

const run = promisify(execFile)

/** HEIC, TIFF and the rest ImageIO reads, as PNG, through a temp folder removed at once. */
async function decodeWithSips(bytes: Uint8Array): Promise<Electron.NativeImage> {
  const folder = await mkdtemp(join(tmpdir(), 'talaria-convert-'))
  try {
    const input = join(folder, 'in')
    const output = join(folder, 'out.png')
    await writeFile(input, bytes)
    await run('/usr/bin/sips', ['-s', 'format', 'png', input, '--out', output], { timeout: 60_000 })
    return nativeImage.createFromBuffer(await readFile(output))
  } catch {
    return nativeImage.createEmpty()
  } finally {
    await rm(folder, { recursive: true, force: true })
  }
}

/** A file name with no folders in it, safe on Windows and macOS. */
function safeName(name: string): string {
  const cleaned = basename(name.replace(/\\/g, '/')).replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_').trim()
  return cleaned === '' || cleaned === '.' || cleaned === '..' ? 'download' : cleaned.slice(0, 200)
}
