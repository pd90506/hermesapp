import { BrowserWindow, Notification, app, ipcMain } from 'electron'
import {
  IPC, type NotificationAction, type NotificationTarget, type Platform, type SystemNotification,
} from '../../shared/bridge.ts'

/**
 * The system's notifications (`talaria.notifications`), after Hermes Desktop's
 * (`apps/desktop/electron/notification-ipc.ts`, `notification-registry.ts`, MIT):
 * - a click brings the window to the front and asks the renderer to open the chat;
 * - an approval's notification has Approve and Reject (macOS shows the buttons);
 * - the same tag within a second shows once;
 * - each notification is held until it is clicked or for 10 minutes, so its handlers
 *   live as long as the toast does in the notification centre;
 * - while the window is not focused, its taskbar or Dock entry asks for attention
 *   until it is.
 */
export function registerNotifications(platform: Platform, getWindow: () => BrowserWindow | undefined): void {
  // Windows names a toast's app by the shortcut's AppUserModelID: electron-builder gives the
  // Start menu shortcut the appId.
  if (platform === 'windows') app.setAppUserModelId('com.example.hermesapp.desktop')

  const live = new Set<Notification>()
  const lastShown = new Map<string, number>()
  const dedupeMs = 1000
  const retentionMs = 10 * 60 * 1000

  const retain = (notification: Notification): void => {
    live.add(notification)
    // Windows sends `close` when the banner times out while Action Center keeps it clickable.
    const events = ['click', 'action', 'failed'] as const
    const release = () => {
      clearTimeout(timer)
      live.delete(notification)
      for (const event of events) notification.removeListener(event as 'click', release)
    }
    for (const event of events) notification.on(event as 'click', release)
    const timer = setTimeout(() => {
      notification.close()
      release()
    }, retentionMs)
    timer.unref()
  }

  const front = (): BrowserWindow | undefined => {
    const window = getWindow()
    if (!window || window.isDestroyed()) return undefined
    if (window.isMinimized()) window.restore()
    window.show()
    if (platform === 'mac') app.focus({ steal: true })
    window.focus()
    return window
  }

  ipcMain.handle(IPC.notificationShow, (_event, payload: SystemNotification) => {
    if (!Notification.isSupported() || !payload || typeof payload.title !== 'string') return false
    const now = Date.now()
    for (const [key, at] of lastShown) if (now - at >= dedupeMs) lastShown.delete(key)
    const tag = typeof payload.tag === 'string' ? payload.tag : ''
    if (tag !== '' && lastShown.has(tag)) return true
    lastShown.set(tag, now)
    const target = payload.target
    const asksApproval = typeof target?.requestID === 'string'
    const notification = new Notification({
      title: payload.title,
      body: typeof payload.body === 'string' ? payload.body : '',
      ...(asksApproval ? { actions: [{ type: 'button', text: 'Approve' }, { type: 'button', text: 'Reject' }] } : {}),
    })
    notification.on('click', () => {
      const window = front()
      if (window && target) window.webContents.send(IPC.notificationClick, target)
    })
    notification.on('action', (actionEvent, legacyIndex) => {
      const window = getWindow()
      if (!window || window.isDestroyed() || !target) return
      const index = typeof (actionEvent as { actionIndex?: unknown })?.actionIndex === 'number'
        ? (actionEvent as { actionIndex: number }).actionIndex
        : legacyIndex
      const action: NotificationAction | undefined = index === 0 ? 'approve' : index === 1 ? 'reject' : undefined
      if (action) window.webContents.send(IPC.notificationAction, target satisfies NotificationTarget, action)
    })
    retain(notification)
    requestAttention(getWindow())
    notification.show()
    return true
  })

  ipcMain.handle(IPC.notificationTest, () => {
    if (!Notification.isSupported()) return false
    const notification = new Notification({ title: 'Talaria', body: 'Notifications are working.' })
    retain(notification)
    notification.show()
    return true
  })
}

const flashing = new WeakSet<BrowserWindow>()

/** The toast is transient: flash the taskbar entry (bounce the Dock icon) until the window is focused. */
function requestAttention(window: BrowserWindow | undefined): void {
  if (!window || window.isDestroyed() || window.isFocused() || flashing.has(window)) return
  flashing.add(window)
  window.flashFrame(true)
  window.once('focus', () => {
    flashing.delete(window)
    if (!window.isDestroyed()) window.flashFrame(false)
  })
}
