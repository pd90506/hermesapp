import { contextBridge, ipcRenderer } from 'electron'
import {
  IPC, frameGeometry, type Appearance, type Platform, type SocketEvent, type TalariaBridge,
} from '../shared/bridge.ts'

const platform: Platform = process.platform === 'win32' ? 'windows' : process.platform === 'darwin' ? 'mac' : 'linux'
/** From the main process (`cjkLanguage`). */
const cjk = (process.argv ?? []).find((arg) => arg.startsWith('--talaria-cjk='))?.split('=')[1] ?? 'zh-Hans'

/**
 * Marks the document with the platform and the frame's geometry before the page's
 * styles apply: the renderer's CSS branches on `data-platform` and these variables
 * only, never on a platform check in code (docs/desktop-electron.md).
 */
function markDocument(): void {
  const root = document.documentElement as HTMLElement | null
  if (!root) return
  const geometry = frameGeometry(platform)
  root.dataset.platform = platform
  root.dataset.cjk = cjk
  root.lang = 'en'
  root.style.setProperty('--frame-title-band-height', `${geometry.titleBandHeight}px`)
  root.style.setProperty('--frame-caption-width', `${geometry.captionWidth}px`)
  root.style.setProperty('--frame-traffic-lights-width', `${geometry.trafficLightsWidth}px`)
}
markDocument()
document.addEventListener('DOMContentLoaded', markDocument, { once: true })

const bridge: TalariaBridge = {
  platform,
  http: {
    send: (request) => ipcRenderer.invoke(IPC.httpSend, request),
    reset: () => ipcRenderer.invoke(IPC.httpReset),
  },
  socket: {
    open: (url) => ipcRenderer.invoke(IPC.socketOpen, url),
    send: (id, text) => ipcRenderer.invoke(IPC.socketSend, id, text),
    close: (id) => ipcRenderer.invoke(IPC.socketClose, id),
    onEvent(handler) {
      const listener = (_event: unknown, event: SocketEvent) => handler(event)
      ipcRenderer.on(IPC.socketEvent, listener)
      return () => ipcRenderer.removeListener(IPC.socketEvent, listener)
    },
  },
  settings: {
    load: () => ipcRenderer.invoke(IPC.settingsLoad),
    save: (settings) => ipcRenderer.invoke(IPC.settingsSave, settings),
  },
  secret: {
    load: () => ipcRenderer.invoke(IPC.secretLoad),
    save: (value) => ipcRenderer.invoke(IPC.secretSave, value),
  },
  appearance: {
    get: () => ipcRenderer.invoke(IPC.appearanceGet),
    onChange(handler) {
      const listener = (_event: unknown, appearance: Appearance) => handler(appearance)
      ipcRenderer.on(IPC.appearanceChanged, listener)
      return () => ipcRenderer.removeListener(IPC.appearanceChanged, listener)
    },
    setCaptionColors: (colors) => ipcRenderer.send(IPC.captionColors, colors),
  },
}

contextBridge.exposeInMainWorld('talaria', bridge)
