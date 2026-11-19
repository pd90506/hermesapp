import { AlertGate, type GatewayAlert, type GatewayConnection } from '@talaria/hermes-core'
import type { NotificationAction, NotificationTarget, SystemNotification } from '../../../shared/bridge.ts'
import type { AppModel } from '../../app/model.ts'

/**
 * Shows every server's alerts (`GatewayConnection.alerts`) as system notifications when
 * the gate lets them through (`AlertGate`, Settings ▸ Notifications), and handles clicks
 * on them and their Approve / Reject (the Mac's `SystemNotifier`, after Hermes Desktop's
 * `native-notifications.ts`).
 *
 * The app is "in front" while its window has focus and shows (Desktop's
 * `isBackgrounded`); a chat is on screen while it is the active chat of the server the
 * sidebar shows.
 */
export class Notifier {
  readonly gate: AlertGate
  private readonly wired = new WeakSet<GatewayConnection>()

  constructor(private readonly model: AppModel, private readonly document: Document = globalThis.document) {
    this.gate = new AlertGate(model.get().alertPreferences)
  }

  /** Follows the settings and the servers, and listens for clicks. Returns the stop. */
  start(): () => void {
    const stops = [
      this.model.subscribe(() => this.follow()),
      this.model.servers.subscribe(() => this.follow()),
      this.model.bridge.notifications.onClick((target) => void this.open(target)),
      this.model.bridge.notifications.onAction((target, action) => this.answer(target, action)),
    ]
    this.follow()
    return () => { for (const stop of stops) stop() }
  }

  get appIsActive(): boolean {
    return !this.document.hidden && this.document.hasFocus()
  }

  private follow(): void {
    this.gate.preferences = this.model.get().alertPreferences
    const current = this.model.get().currentServerID
    for (const entry of this.model.servers.get().servers) {
      const connection = entry.connection
      connection.alerts.isChatOnScreen = entry.id === current
      if (this.wired.has(connection)) continue
      this.wired.add(connection)
      connection.alerts.sink = (alert) => this.show(alert, entry.id)
    }
  }

  /** Shows `alert` from server `serverID` if the gate lets it through; says whether it did. */
  show(alert: GatewayAlert, serverID: string): boolean {
    if (!this.gate.admit(alert, this.appIsActive)) return false
    const target: NotificationTarget = {
      serverID,
      isBotChat: alert.isBotChat,
      ...(alert.profile !== undefined ? { profile: alert.profile } : {}),
      ...(alert.storedSessionID !== undefined ? { storedSessionID: alert.storedSessionID } : {}),
      ...(alert.requestID !== undefined && alert.kind === 'approval' ? { requestID: alert.requestID } : {}),
    }
    const notification: SystemNotification = {
      title: notificationTitle(alert),
      body: alert.body,
      tag: `${serverID}/${alert.kind}:${alert.sessionID ?? alert.storedSessionID ?? ''}`,
      target,
    }
    void this.model.bridge.notifications.show(notification).catch(() => false)
    return true
  }

  /** A click: the chat it is about, on screen (the Mac's `AlertTarget`). */
  async open(target: NotificationTarget): Promise<void> {
    const entry = this.model.servers.server(target.serverID)
    if (!entry || target.profile === undefined) return
    this.model.closeSettings()
    this.model.selectProfile(target.serverID, target.profile)
    const chats = entry.connection.chats
    const active = chats.active
    if (target.isBotChat) {
      if (active?.kind === 'botChat' && active.profile === target.profile) return
      await chats.openBotChat(target.profile).catch(() => {})
      return
    }
    const stored = target.storedSessionID
    if (!stored || (active?.storedSessionID === stored && active.profile === target.profile)) return
    const row = entry.connection.get().sessions[target.profile]?.find((each) => each.id === stored)
    await chats.openSession(target.profile, row ?? { id: stored }).catch(() => {})
  }

  /** Approve or Reject on an approval's notification. */
  answer(target: NotificationTarget, action: NotificationAction): void {
    if (!target.requestID) return
    try {
      this.model.servers.server(target.serverID)?.connection.alerts.answerApproval(target.requestID, action === 'approve' ? 'once' : 'deny')
    } catch {
      // Disconnected meanwhile: the request waits for its card.
    }
  }
}

/**
 * The title names the chat ("Approval needed — Fix the flaky test"), as Desktop names a
 * prompt's session: Electron shows a subtitle on macOS only.
 */
export function notificationTitle(alert: GatewayAlert): string {
  const name = alert.subtitle?.trim()
  if (!name) return alert.title
  return `${alert.title} — ${name.length > 80 ? `${name.slice(0, 80).trimEnd()}…` : name}`
}

/** Starts the app's notifications (main.tsx). */
export function startNotifications(model: AppModel): () => void {
  return new Notifier(model).start()
}
