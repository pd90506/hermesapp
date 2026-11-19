import { app, ipcMain, nativeTheme } from 'electron'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { IPC, type AppearanceMode } from '../../shared/bridge.ts'

/**
 * Light, dark or the system's look for the whole app (Settings ▸ Appearance), as the
 * Mac app sets `NSApp.appearance`: `nativeTheme.themeSource`, which the page's
 * prefers-color-scheme, the Mica or vibrancy material, menus and the caption buttons
 * all follow. The page keeps the setting (settings.json, `appearance.theme`); the saved
 * look applies before the first window opens, so it never flashes the other one.
 */
export function registerAppearance(): void {
  nativeTheme.themeSource = savedMode()
  ipcMain.on(IPC.themeSetMode, (_event, mode: unknown) => {
    if (isMode(mode)) nativeTheme.themeSource = mode
  })
}

function isMode(value: unknown): value is AppearanceMode {
  return value === 'system' || value === 'light' || value === 'dark'
}

function savedMode(): AppearanceMode {
  try {
    const settings = JSON.parse(readFileSync(join(app.getPath('userData'), 'settings.json'), 'utf8')) as {
      appearance?: { theme?: unknown }
    }
    const mode = settings.appearance?.theme
    return isMode(mode) ? mode : 'system'
  } catch {
    return 'system'
  }
}
