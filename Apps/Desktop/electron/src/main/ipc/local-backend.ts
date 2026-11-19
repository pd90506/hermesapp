import { app, ipcMain } from 'electron'
import { spawn, type ChildProcess } from 'node:child_process'
import { access, constants } from 'node:fs/promises'
import { homedir } from 'node:os'
import {
  hermesCandidates, localBackendLaunch, outputTail, randomToken, readyPort, type LocalPlatform,
} from '@talaria/hermes-core'
import { IPC } from '../../shared/bridge.ts'

/**
 * The Hermes the app runs on this computer (K; the Mac's `LocalBackendProcess`):
 * `hermes serve` on a loopback port the OS picks, with a fresh token each start, stopped
 * when asked and when the app quits (and by its parent watchdog if the app dies).
 */
let child: ChildProcess | undefined
let running: { port: number; token: string } | undefined
let starting: Promise<{ port: number; token: string }> | undefined

async function findHermes(platform: LocalPlatform): Promise<string | undefined> {
  const env = process.env
  const candidates = hermesCandidates(platform, {
    home: homedir(),
    ...(env.LOCALAPPDATA ? { localAppData: env.LOCALAPPDATA } : {}),
    ...(env.HERMES_HOME ? { hermesHome: env.HERMES_HOME } : {}),
    ...(env.PATH ?? env.Path ? { path: env.PATH ?? env.Path } : {}),
  })
  for (const candidate of candidates) {
    try {
      await access(candidate, platform === 'windows' ? constants.F_OK : constants.X_OK)
      return candidate
    } catch {}
  }
  return undefined
}

function isRunning(): boolean {
  return child !== undefined && child.exitCode === null && child.signalCode === null && running !== undefined
}

async function start(platform: LocalPlatform): Promise<{ port: number; token: string }> {
  if (isRunning()) return running!
  if (starting) return starting
  starting = (async () => {
    stopNow()
    const hermes = await findHermes(platform)
    if (!hermes) {
      throw new Error(platform === 'windows'
        ? 'Hermes isn’t installed on this PC (no hermes.exe in %LOCALAPPDATA%\\hermes or PATH).'
        : 'Hermes isn’t installed on this Mac (no `hermes` in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin or PATH).')
    }
    const token = randomToken()
    const launch = localBackendLaunch(platform, hermes, token, process.pid, process.env, homedir())
    const process_ = spawn(launch.executable, launch.arguments, {
      cwd: homedir(),
      env: launch.environment as NodeJS.ProcessEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    })
    child = process_
    let output = ''
    const port = await new Promise<number>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Hermes didn’t get ready in time.' + outputTail(output))), 90_000)
      // Always drained, also after start: a full pipe would block the backend.
      const read = (chunk: Buffer) => {
        output = (output + chunk.toString('utf8')).slice(-8192)
        const found = readyPort(output)
        if (found !== undefined) {
          clearTimeout(timer)
          resolve(found)
        }
      }
      process_.stdout?.on('data', read)
      process_.stderr?.on('data', read)
      process_.once('error', (error) => {
        clearTimeout(timer)
        reject(new Error(`Couldn’t start Hermes: ${error.message}`))
      })
      process_.once('exit', (code) => {
        clearTimeout(timer)
        setTimeout(() => reject(new Error(`Hermes exited (status ${code ?? -1}) before it was ready.` + outputTail(output))), 100)
      })
    })
    running = { port, token }
    process_.once('exit', () => {
      if (child === process_) {
        child = undefined
        running = undefined
      }
    })
    return running
  })()
  try {
    return await starting
  } catch (error) {
    stopNow()
    throw error
  } finally {
    starting = undefined
  }
}

function stopNow(): void {
  const current = child
  child = undefined
  running = undefined
  if (current && current.exitCode === null) current.kill()
}

async function stop(): Promise<void> {
  const current = child
  stopNow()
  if (!current || current.exitCode !== null) return
  for (let i = 0; i < 50 && current.exitCode === null && current.signalCode === null; i++) {
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  if (current.exitCode === null && current.signalCode === null) current.kill('SIGKILL')
}

export function registerLocalBackend(platform: LocalPlatform): void {
  ipcMain.handle(IPC.localBackendAvailable, async () => (await findHermes(platform)) !== undefined)
  ipcMain.handle(IPC.localBackendStart, () => start(platform))
  ipcMain.handle(IPC.localBackendStop, () => stop())
  ipcMain.handle(IPC.localBackendRunning, () => isRunning())
  app.on('will-quit', stopNow)
}
