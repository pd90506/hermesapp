import { BrowserWindow, app, ipcMain, nativeTheme, shell, systemPreferences } from 'electron'
import { join } from 'node:path'
import { IPC, type Appearance, type BridgeHttpRequest, type SavedSettings } from '../shared/bridge.ts'
import { DashboardHttp } from './dashboard-http.ts'
import { Sockets } from './sockets.ts'
import { loadSecret, loadSettings, saveSecret, saveSettings } from './store.ts'
import { cjkLanguage } from './cjk.ts'
import { registerLinks } from './ipc/links.ts'
import { captionSymbolColor, currentPlatform, windowFrameOptions } from './window-frame.ts'

// Its own data folder, `Talaria Desktop`: `Talaria` was the (now removed) Flutter app's,
// with another settings.json, and may still be on a machine.
app.setPath('userData', join(app.getPath('appData'), 'Talaria Desktop'))

const platform = currentPlatform()
// Windows 11's thin overlay scrollbars (Chromium's Fluent scrollbars), not the classic
// arrowed ones; macOS draws its own overlay scrollbars already.
if (platform === 'windows') app.commandLine.appendSwitch('enable-features', 'FluentOverlayScrollbar')
const http = new DashboardHttp()
const sockets = new Sockets()
let window: BrowserWindow | undefined

if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (!window) return
    if (window.isMinimized()) window.restore()
    window.focus()
  })
  app.whenReady().then(start)
  app.on('window-all-closed', () => {
    if (platform !== 'mac') app.quit()
  })
  app.on('activate', () => {
    if (!window) createWindow()
  })
}

function appearance(): Appearance {
  const dark = nativeTheme.shouldUseDarkColors
  let accent: string | undefined
  if (platform === 'windows' || platform === 'mac') {
    // `RRGGBBAA` on both.
    const value = systemPreferences.getAccentColor?.()
    if (value && /^[0-9a-f]{6,8}$/i.test(value)) accent = `#${value.slice(0, 6)}`
  }
  return accent ? { dark, accent } : { dark }
}

function createWindow(): void {
  const created = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 720,
    minHeight: 480,
    show: false,
    title: 'Talaria',
    ...windowFrameOptions(platform),
    webPreferences: {
      preload: join(__dirname, '../preload/preload.cjs'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      webSecurity: true,
      spellcheck: false,
      additionalArguments: [`--talaria-cjk=${cjkLanguage(app.getPreferredSystemLanguages())}`],
    },
  })
  window = created
  created.once('ready-to-show', () => created.show())
  created.on('closed', () => {
    if (window === created) window = undefined
  })
  // Links open in the browser; the window never navigates away from the app.
  created.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) void shell.openExternal(url)
    return { action: 'deny' }
  })
  created.webContents.on('will-navigate', (event) => event.preventDefault())
  const devServer = process.env.TALARIA_DEV_SERVER
  if (devServer) void created.loadURL(devServer)
  else void created.loadFile(join(__dirname, '../renderer/index.html'))
}

function start(): void {
  ipcMain.handle(IPC.httpSend, (_event, request: BridgeHttpRequest) => http.send(request))
  ipcMain.handle(IPC.httpReset, () => http.reset())
  ipcMain.handle(IPC.socketOpen, (event, url: string) => sockets.connect(event.sender, url))
  ipcMain.handle(IPC.socketSend, (_event, id: number, text: string) => sockets.send(id, text))
  ipcMain.handle(IPC.socketClose, (_event, id: number) => sockets.close(id))
  ipcMain.handle(IPC.settingsLoad, () => loadSettings())
  ipcMain.handle(IPC.settingsSave, (_event, settings: SavedSettings) => saveSettings(settings))
  ipcMain.handle(IPC.secretLoad, () => loadSecret())
  ipcMain.handle(IPC.secretSave, (_event, value: string | null) => saveSecret(value))
  ipcMain.handle(IPC.appearanceGet, () => appearance())
  registerLinks()
  ipcMain.on(IPC.captionColors, (event, colors: { symbol: string }) => {
    const owner = BrowserWindow.fromWebContents(event.sender)
    if (!owner || platform === 'mac' || !/^#[0-9a-f]{6}$/i.test(colors.symbol)) return
    owner.setTitleBarOverlay({ color: '#00000000', symbolColor: colors.symbol })
  })

  const broadcast = () => {
    const current = appearance()
    for (const each of BrowserWindow.getAllWindows()) {
      each.webContents.send(IPC.appearanceChanged, current)
      if (platform !== 'mac') {
        each.setTitleBarOverlay({ color: '#00000000', symbolColor: captionSymbolColor(current.dark) })
      }
    }
  }
  nativeTheme.on('updated', broadcast)
  if (platform === 'windows' || platform === 'mac') systemPreferences.on('accent-color-changed', broadcast)

  createWindow()
}
