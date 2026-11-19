import { app, safeStorage } from 'electron'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { SavedSettings } from '../shared/bridge.ts'

/**
 * Settings and the server's secret, in the app's own data folder
 * (`%APPDATA%\Talaria Desktop`, `~/Library/Application Support/Talaria Desktop`).
 * The secret is encrypted with the OS's store through `safeStorage`: DPAPI on Windows,
 * the Keychain on macOS. It is never written in the clear.
 */
const folder = () => app.getPath('userData')
const settingsFile = () => join(folder(), 'settings.json')
const secretFile = () => join(folder(), 'server-secret.bin')

async function writeAtomically(path: string, data: string | Buffer): Promise<void> {
  await mkdir(folder(), { recursive: true })
  const temporary = `${path}.writing`
  await writeFile(temporary, data, { mode: 0o600 })
  await rename(temporary, path)
}

export async function loadSettings(): Promise<SavedSettings> {
  try {
    // A BOM (Windows PowerShell 5.1 writes one) would make the whole file unreadable.
    return JSON.parse((await readFile(settingsFile(), 'utf8')).replace(/^\uFEFF/, '')) as SavedSettings
  } catch {
    return {}
  }
}

export async function saveSettings(settings: SavedSettings): Promise<void> {
  await writeAtomically(settingsFile(), JSON.stringify(settings, null, 2))
}

export async function loadSecret(): Promise<{ value: string | null; available: boolean }> {
  if (!safeStorage.isEncryptionAvailable()) return { value: null, available: false }
  try {
    return { value: safeStorage.decryptString(await readFile(secretFile())), available: true }
  } catch {
    return { value: null, available: true }
  }
}

export async function saveSecret(value: string | null): Promise<void> {
  if (value === null) {
    await rm(secretFile(), { force: true })
    return
  }
  if (!safeStorage.isEncryptionAvailable()) throw new Error('The system keychain is not available')
  await writeAtomically(secretFile(), safeStorage.encryptString(value))
}

/** Each server's secret, `secrets/<id>.bin` (K: several servers). */
const serverSecretFile = (id: string) => {
  if (!/^[A-Za-z0-9-]{1,64}$/.test(id)) throw new Error('Not a server id')
  return join(folder(), 'secrets', `${id}.bin`)
}

export async function loadServerSecret(id: string): Promise<{ value: string | null; available: boolean }> {
  if (!safeStorage.isEncryptionAvailable()) return { value: null, available: false }
  try {
    return { value: safeStorage.decryptString(await readFile(serverSecretFile(id))), available: true }
  } catch {
    return { value: null, available: true }
  }
}

export async function saveServerSecret(id: string, value: string | null): Promise<void> {
  const path = serverSecretFile(id)
  if (value === null) {
    await rm(path, { force: true })
    return
  }
  if (!safeStorage.isEncryptionAvailable()) throw new Error('The system keychain is not available')
  await mkdir(join(folder(), 'secrets'), { recursive: true })
  const temporary = `${path}.writing`
  await writeFile(temporary, safeStorage.encryptString(value), { mode: 0o600 })
  await rename(temporary, path)
}
