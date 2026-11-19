import {
  BrowserWindow, Menu, app, ipcMain, nativeTheme, type BrowserWindowConstructorOptions, type HandlerDetails,
  type MenuItemConstructorOptions, type WindowOpenHandlerResponse,
} from 'electron'
import { release } from 'node:os'
import { IPC, settingsWindowName, type Platform } from '../../shared/bridge.ts'
import { captionSymbolColor } from '../window-frame.ts'

/**
 * The Settings window (K). The main window's renderer opens it with
 * `window.open('about:blank', 'talaria-settings')` and draws the panes into it with a
 * React portal, so the panes share the main window's state and connections; this file
 * gives that window its native frame, its size, and the shortcut that opens it:
 * - macOS: an app-menu Settings… item with ⌘, (as every Mac app), a fixed-width window
 *   whose height follows the pane, the traffic lights in its toolbar.
 * - Windows: Ctrl+, in the main window, a dialog-like window with Mica and the system
 *   close button over the page's top right (Window Controls Overlay).
 */
let settings: BrowserWindow | undefined

/** The Settings window's title band: the Mac's unified toolbar with icon tabs, or WinUI's 48 px title bar. */
export function settingsTitleBandHeight(platform: Platform): number {
  return platform === 'mac' ? 28 : 48
}

function settingsWindowOptions(platform: Platform, parent: BrowserWindow): BrowserWindowConstructorOptions {
  const dark = nativeTheme.shouldUseDarkColors
  const common: BrowserWindowConstructorOptions = {
    title: 'Settings',
    width: 760,
    height: 480,
    useContentSize: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    show: false,
  }
  // Centred over the main window, as a settings window first opens.
  const bounds = parent.getBounds()
  const placed = { x: Math.round(bounds.x + (bounds.width - 760) / 2), y: Math.round(bounds.y + 60) }
  switch (platform) {
    case 'mac':
      return {
        ...common,
        ...placed,
        titleBarStyle: 'hidden',
        trafficLightPosition: { x: 12, y: 8 },
        vibrancy: 'window',
        visualEffectState: 'followWindow',
      }
    case 'windows': {
      const mica = Number(release().split('.')[2] ?? 0) >= 22621
      return {
        ...common,
        ...placed,
        titleBarStyle: 'hidden',
        titleBarOverlay: { color: '#00000000', symbolColor: captionSymbolColor(dark), height: settingsTitleBandHeight(platform) },
        ...(mica ? { backgroundMaterial: 'mica' as const } : { backgroundColor: dark ? '#202020' : '#f3f3f3' }),
      }
    }
    case 'linux':
      return {
        ...common,
        ...placed,
        titleBarStyle: 'hidden',
        titleBarOverlay: { color: '#00000000', symbolColor: captionSymbolColor(dark), height: settingsTitleBandHeight(platform) },
        backgroundColor: dark ? '#202020' : '#f3f3f3',
      }
  }
}

/** For the main window's `setWindowOpenHandler`: the Settings window, or undefined for anything else. */
export function openSettingsWindow(platform: Platform, parent: BrowserWindow, details: HandlerDetails):
  WindowOpenHandlerResponse | undefined {
  if (details.frameName !== settingsWindowName || details.url !== 'about:blank') return undefined
  return { action: 'allow', overrideBrowserWindowOptions: settingsWindowOptions(platform, parent) }
}

/** Wires a main window: keeps its Settings window, Ctrl+, off the Mac. */
export function attachSettingsWindow(platform: Platform, window: BrowserWindow): void {
  window.webContents.on('did-create-window', (child, details) => {
    if (details.frameName !== settingsWindowName) return
    settings = child
    child.setMenuBarVisibility(false)
    child.once('ready-to-show', () => child.show())
    // about:blank fires no ready-to-show on some platforms: show it once it has a size.
    setTimeout(() => { if (!child.isDestroyed() && !child.isVisible()) child.show() }, 300)
    child.on('closed', () => { if (settings === child) settings = undefined })
    child.webContents.on('before-input-event', (event, input) => {
      // Escape closes a settings window on Windows, as a dialog; ⌘W on the Mac (menu).
      if (platform !== 'mac' && input.type === 'keyDown' && input.key === 'Escape') {
        event.preventDefault()
        child.close()
      }
    })
  })
  if (platform !== 'mac') {
    window.webContents.on('before-input-event', (event, input) => {
      if (input.type === 'keyDown' && input.control && !input.alt && !input.meta && input.key === ',') {
        event.preventDefault()
        window.webContents.send(IPC.settingsOpen)
      }
    })
  }
  window.on('closed', () => {
    if (settings && !settings.isDestroyed()) settings.close()
  })
}

/** The IPC handlers, and on the Mac the app menu with Settings… (⌘,). */
export function registerSettingsWindow(platform: Platform, mainWindow: () => BrowserWindow | undefined): void {
  ipcMain.on(IPC.settingsSize, (_event, width: unknown, height: unknown) => {
    if (!settings || settings.isDestroyed()) return
    if (typeof width !== 'number' || typeof height !== 'number' || !(width > 0) || !(height > 0)) return
    const [w, h] = [Math.min(Math.round(width), 1600), Math.min(Math.round(height), 1200)]
    // A smooth resize on the Mac, as its settings windows change height with the tab.
    settings.setContentSize(w, h, platform === 'mac' && settings.isVisible())
  })
  if (platform === 'mac') Menu.setApplicationMenu(Menu.buildFromTemplate(macMenu(mainWindow)))
}

function macMenu(mainWindow: () => BrowserWindow | undefined): MenuItemConstructorOptions[] {
  return [
    {
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        {
          label: 'Settings…',
          accelerator: 'Command+,',
          click: () => {
            const window = mainWindow()
            if (window) window.webContents.send(IPC.settingsOpen)
          },
        },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    { role: 'editMenu' },
    { role: 'viewMenu' },
    { role: 'windowMenu' },
  ]
}
