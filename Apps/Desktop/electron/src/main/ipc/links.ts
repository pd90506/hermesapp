import { ipcMain, shell } from 'electron'
import { externalLinkTarget } from '@talaria/hermes-core'
import { IPC } from '../../shared/bridge.ts'

/**
 * Links in messages open in the system's browser or mail app, never in the window
 * (`talaria.links`). The address is checked again here: the renderer shows text a
 * model wrote, so only web and mail addresses reach the system.
 */
export function registerLinks(): void {
  ipcMain.handle(IPC.linksOpen, async (_event, url: unknown) => {
    const target = typeof url === 'string' ? externalLinkTarget(url) : undefined
    if (!target) return false
    await shell.openExternal(target)
    return true
  })
}
