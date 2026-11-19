import { BrowserWindow, Menu, ipcMain, type MenuItemConstructorOptions } from 'electron'
import { IPC, type MenuEntry, type MenuOutcome, type Platform } from '../../shared/bridge.ts'

/**
 * Context menus. On macOS the system's own menu (`Menu.popup`), as the Mac app's
 * `.contextMenu`; elsewhere the renderer draws a Fluent flyout (`ui/ContextMenu`),
 * since Win32 popup menus don't look like Windows 11's WinUI menus.
 */
export function registerMenuIPC(platform: Platform): void {
  ipcMain.handle(IPC.menuPopup, (event, entries: MenuEntry[], x: number, y: number): Promise<MenuOutcome> => {
    const owner = BrowserWindow.fromWebContents(event.sender)
    if (platform !== 'mac' || !owner) return Promise.resolve({ kind: 'inApp' })
    return popupNative(owner, entries, x, y)
  })
}

function popupNative(owner: BrowserWindow, entries: MenuEntry[], x: number, y: number): Promise<MenuOutcome> {
  return new Promise((resolve) => {
    let settled = false
    const finish = (outcome: MenuOutcome) => {
      if (settled) return
      settled = true
      resolve(outcome)
    }
    const build = (list: MenuEntry[]): MenuItemConstructorOptions[] => list.map((entry) => {
      switch (entry.kind) {
        case 'separator': return { type: 'separator' }
        case 'submenu': return { label: entry.label, enabled: !entry.disabled, submenu: build(entry.entries) }
        case 'item': return {
          label: entry.label,
          enabled: !entry.disabled,
          ...(entry.checked !== undefined ? { type: 'checkbox' as const, checked: entry.checked } : {}),
          click: () => finish({ kind: 'chosen', id: entry.id }),
        }
      }
    })
    Menu.buildFromTemplate(build(entries)).popup({
      window: owner,
      x: Math.round(x),
      y: Math.round(y),
      // The close comes before an item's click on some systems: give the click a turn.
      callback: () => setTimeout(() => finish({ kind: 'dismissed' }), 50),
    })
  })
}
