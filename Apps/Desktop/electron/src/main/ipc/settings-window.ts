import { BrowserWindow, Menu, app, type MenuItemConstructorOptions } from 'electron'
import { IPC, type Platform } from '../../shared/bridge.ts'

/**
 * The shortcuts that open Settings (K). Settings itself is an overlay the renderer draws
 * in the main window (`features/settings`), the same on every platform; the main process
 * only gives it its keyboard shortcut: Settings… (⌘,) in the Mac app menu, Ctrl+, elsewhere.
 */

/** Ctrl+, in a main window, off the Mac (the Mac has the menu's ⌘,). */
export function attachSettingsShortcut(platform: Platform, window: BrowserWindow): void {
  if (platform === 'mac') return
  window.webContents.on('before-input-event', (event, input) => {
    if (input.type === 'keyDown' && input.control && !input.alt && !input.meta && input.key === ',') {
      event.preventDefault()
      window.webContents.send(IPC.settingsOpen)
    }
  })
}

/** On the Mac, the app menu with Settings… (⌘,). */
export function registerSettingsMenu(platform: Platform, mainWindow: () => BrowserWindow | undefined): void {
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
          click: () => mainWindow()?.webContents.send(IPC.settingsOpen),
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
