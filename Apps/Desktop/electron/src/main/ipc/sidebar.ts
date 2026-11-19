import { app, ipcMain } from 'electron'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { IPC } from '../../shared/bridge.ts'

/**
 * What the sidebar keeps across launches (`SessionSidebar`): pins, read marks and each
 * server's lists as read last, in `sidebar.json` beside the settings. Writes are
 * serialised, each replacing the file whole.
 */
const file = () => join(app.getPath('userData'), 'sidebar.json')
let writing: Promise<void> = Promise.resolve()

export function registerSidebarIPC(): void {
  ipcMain.handle(IPC.sidebarLoad, async () => {
    try {
      return JSON.parse(await readFile(file(), 'utf8')) as unknown
    } catch {
      return undefined
    }
  })
  ipcMain.handle(IPC.sidebarSave, (_event, value: unknown) => {
    const text = JSON.stringify(value)
    writing = writing.catch(() => {}).then(async () => {
      await mkdir(app.getPath('userData'), { recursive: true })
      const temporary = `${file()}.writing`
      await writeFile(temporary, text, { mode: 0o600 })
      await rename(temporary, file())
    })
    return writing
  })
}
