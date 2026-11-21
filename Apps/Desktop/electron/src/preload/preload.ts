import { contextBridge, ipcRenderer, webUtils } from 'electron'
import {
  IPC, frameGeometry, sidebarShortcuts, type Appearance, type NotificationAction, type NotificationTarget, type Platform,
  type SocketEvent, type TalariaBridge,
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
  secrets: {
    load: (id) => ipcRenderer.invoke(IPC.secretsLoad, id),
    save: (id, value) => ipcRenderer.invoke(IPC.secretsSave, id, value),
  },
  settingsWindow: {
    onOpenRequest(handler) {
      const listener = () => handler()
      ipcRenderer.on(IPC.settingsOpen, listener)
      return () => ipcRenderer.removeListener(IPC.settingsOpen, listener)
    },
  },
  signIn: {
    listen: () => ipcRenderer.invoke(IPC.signInListen),
    callback: (id) => ipcRenderer.invoke(IPC.signInCallback, id),
    stop: (id) => ipcRenderer.invoke(IPC.signInStop, id),
    openExternal: (url) => ipcRenderer.invoke(IPC.signInOpen, url),
  },
  localBackend: {
    available: () => ipcRenderer.invoke(IPC.localBackendAvailable),
    start: () => ipcRenderer.invoke(IPC.localBackendStart),
    stop: () => ipcRenderer.invoke(IPC.localBackendStop),
    isRunning: () => ipcRenderer.invoke(IPC.localBackendRunning),
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
  sidebar: {
    load: () => ipcRenderer.invoke(IPC.sidebarLoad),
    save: (value) => ipcRenderer.invoke(IPC.sidebarSave, value),
  },
  shortcuts: sidebarShortcuts(platform),
  links: {
    open: (url) => ipcRenderer.invoke(IPC.linksOpen, url),
  },
  theme: {
    setMode: (mode) => ipcRenderer.send(IPC.themeSetMode, mode),
  },
  /* J: notifications */
  notifications: {
    show: (notification) => ipcRenderer.invoke(IPC.notificationShow, notification),
    test: () => ipcRenderer.invoke(IPC.notificationTest),
    onClick(handler) {
      const listener = (_event: unknown, target: NotificationTarget) => handler(target)
      ipcRenderer.on(IPC.notificationClick, listener)
      return () => ipcRenderer.removeListener(IPC.notificationClick, listener)
    },
    onAction(handler) {
      const listener = (_event: unknown, target: NotificationTarget, action: NotificationAction) => handler(target, action)
      ipcRenderer.on(IPC.notificationAction, listener)
      return () => ipcRenderer.removeListener(IPC.notificationAction, listener)
    },
  },
  files: {
    pick: () => ipcRenderer.invoke(IPC.filesPick),
    read: (path) => ipcRenderer.invoke(IPC.filesRead, path),
    pathFor: (file) => {
      try {
        return webUtils.getPathForFile(file)
      } catch {
        return ''
      }
    },
    convertImage: (bytes, options) => ipcRenderer.invoke(IPC.filesConvertImage, bytes, options),
    download: (request, name) => ipcRenderer.invoke(IPC.filesDownload, request, name),
    open: (path) => ipcRenderer.invoke(IPC.filesOpen, path),
    saveAs: (path, name) => ipcRenderer.invoke(IPC.filesSaveAs, path, name),
  },
  embeds: {
    hostWidget: (html) => ipcRenderer.invoke(IPC.embedsHostWidget, html),
    releaseWidget: (url) => ipcRenderer.send(IPC.embedsReleaseWidget, url),
    remoteImage: (url) => ipcRenderer.invoke(IPC.embedsRemoteImage, url),
  },
}

contextBridge.exposeInMainWorld('talaria', bridge)
