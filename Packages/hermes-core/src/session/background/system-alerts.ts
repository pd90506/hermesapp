import type { Bot, SessionSummary } from '../../bots.ts'
import { GatewayClientError, type GatewayClient, type Inbound } from '../../client.ts'
import { isAlertOn, type AlertKind, type AlertPreferences } from '../../settings/alerts.ts'
import type { ChatSession } from '../chat-session.ts'
import { completeText, eventKind, requestKind, requestSessionID, type ApprovalChoice, type ServerRequest } from '../types.ts'
import { backgroundAlertBody, type BackgroundProcess } from './background-processes.ts'

/**
 * A system notification a connection would show (HermesKit's `GatewayAlert`); the app
 * decides with `AlertGate` whether it does.
 */
export interface GatewayAlert {
  kind: AlertKind
  title: string
  /** The chat it is about, by name. */
  subtitle?: string
  body: string
  /** The runtime session it came from, if any. */
  sessionID?: string
  /** The chat to open when the notification is clicked, if known. */
  storedSessionID?: string
  profile?: string
  isBotChat: boolean
  /** The chat is its connection's active one (on screen, or the last one shown). */
  isActiveChat: boolean
  /** The chat is on screen: active, and the chat pane in view. */
  isOnScreen: boolean
  /** An approval's server request id, for the notification's Approve / Reject. */
  requestID?: string
}

/** Desktop's titles (`notifications.native`, `apps/desktop/src/i18n/en.ts:473-487`). */
export const AlertTitle = {
  approval: 'Approval needed',
  input: 'Input needed',
  turnDone: 'Hermes finished',
  turnError: 'Turn failed',
  backgroundDone: 'Background task finished',
  backgroundFailed: 'Background task failed',
  credits: 'Credits',
  otherReply: 'New reply',
} as const

export const turnDoneBody = 'Message complete.'
export const inputBody = 'Hermes is waiting for your response.'

/** A reply's text as a body: trimmed, at most 140 characters, else the fallback (`turnDoneNotificationBody`). */
export function alertBody(text: string | undefined | null, fallback = turnDoneBody): string {
  const reply = (text ?? '').trim()
  const source = [...(reply === '' ? fallback : reply)]
  return source.length <= 140 ? source.join('') : source.slice(0, 140).join('')
}

/**
 * Whether an alert is shown, as Desktop decides (`shouldFire` and `throttled`,
 * `native-notifications.ts:111-158`; HermesKit's `AlertGate`):
 * - kinds the user switched off never show;
 * - credits notices are not about one chat: they show whenever the app is away;
 * - approvals and questions show while the app is away, or for a chat not on screen;
 * - finished and failed turns show only for the active chat, only while the app is away,
 *   so a busy gateway can't raise one per background session;
 * - replies in other chats (`otherReply`) show only while the app is away;
 * - with `showsInApp`, while the app is in front, finished and failed turns,
 *   `/background` tasks and other replies also show for any chat not on screen;
 * - the same kind for the same chat shows at most once a second (replayed events).
 */
export class AlertGate {
  static readonly throttleMs = 1000
  private lastShown = new Map<string, number>()

  constructor(public preferences: AlertPreferences) {}

  /** Whether to show `alert`, `appIsActive` saying whether the app is in front. A `true` counts toward the throttle. */
  admit(alert: GatewayAlert, appIsActive: boolean, now = Date.now()): boolean {
    if (!isAlertOn(this.preferences, alert.kind)) return false
    let fires: boolean
    switch (alert.kind) {
      case 'credits':
        fires = !appIsActive
        break
      case 'approval': case 'input':
        fires = !appIsActive || !alert.isOnScreen
        break
      default:
        fires = appIsActive
          ? this.preferences.showsInApp && !alert.isOnScreen
          : alert.kind === 'otherReply' || alert.isActiveChat
    }
    if (!fires) return false
    for (const [key, at] of this.lastShown) if (now - at >= AlertGate.throttleMs) this.lastShown.delete(key)
    const key = `${alert.kind}:${alert.sessionID ?? alert.storedSessionID ?? ''}`
    if (this.lastShown.has(key)) return false
    this.lastShown.set(key, now)
    return true
  }
}

/** What the alerts read from their connection (`GatewayConnection`). */
export interface AlertsHost {
  readonly client: GatewayClient | undefined
  readonly active: ChatSession | undefined
  readonly warm: readonly ChatSession[]
  readonly bots: readonly Bot[]
  /** A listed session row of `profile`, for its title. */
  sessionRow(profile: string, storedID: string): SessionSummary | undefined
  /** Requests of chats not on screen (`ChatManager.otherRequests`). */
  readonly otherRequests: readonly ServerRequest[]
  dropOtherRequest(id: string): void
}

/**
 * A connection's system notifications (HermesKit's `GatewayConnection+Alerts`): raised
 * live from the socket's events and server requests (finished and failed turns,
 * `/background` tasks, credits notices, approvals, sudo and secret prompts) and when a
 * chat's background process finishes, as Desktop raises them
 * (`apps/desktop/src/app/session/hooks/use-message-stream/`). The app's `sink` decides
 * (`AlertGate`) and shows them.
 *
 * Replies in chats this socket doesn't follow (`otherReply`) need the session list's
 * unread state, which this version does not read yet.
 */
export class ConnectionAlerts {
  /**
   * After a connect, the socket re-delivers what was already there (parked requests,
   * replayed events): no live alert for that long (`SEED_QUIET_MS`, `notify-baseline.ts`).
   */
  static readonly quietWindowMs = 4000
  /** Credits notices worth a system notification (`NATIVE_NOTICE_KEYS`, `agent-notices.ts:32,205`). */
  static readonly noticeKeys: ReadonlySet<string> = new Set(['credits.depleted', 'credits.window_limit', 'credits.restored'])

  /** Shows an alert; answers whether it did. Unset: no alerts. */
  sink?: (alert: GatewayAlert) => boolean
  /** Whether the chat pane is in view (Settings may cover it). */
  isChatOnScreen = true
  private quietUntil = 0

  constructor(private readonly host: AlertsHost, private readonly now: () => number = Date.now) {}

  /** A socket connected: what it re-delivers first is not news. */
  connected(): void {
    this.quietUntil = this.now() + ConnectionAlerts.quietWindowMs
  }

  /** Takes what the socket delivers, after the chats did. */
  handle(item: Inbound): void {
    if (!this.sink || this.now() < this.quietUntil) return
    if (item.kind === 'event') this.raiseForEvent(item.event.type, item.event.session_id ?? '', item.event)
    else if (item.kind === 'serverRequest') this.raiseForRequest(item.request)
  }

  private raiseForEvent(_type: string, sid: string, event: Parameters<typeof eventKind>[0]): void {
    const kind = eventKind(event)
    switch (kind.kind) {
      case 'messageComplete': {
        const complete = kind.complete
        if (complete.status === 'interrupted') return
        if (complete.status === 'error') {
          this.send(this.chatAlert('turnError', AlertTitle.turnError, sid, alertBody(complete.error, 'The turn failed.')))
          return
        }
        this.send(this.chatAlert('turnDone', AlertTitle.turnDone, sid, alertBody(completeText(complete))))
        return
      }
      case 'error':
        this.send(this.chatAlert('turnError', AlertTitle.turnError, sid, alertBody(kind.message, 'The turn failed.')))
        return
      case 'backgroundComplete':
        this.send(this.chatAlert('backgroundDone', AlertTitle.backgroundDone, sid, alertBody(kind.answer.text, 'Done.')))
        return
      case 'notificationShow': {
        const notice = kind.notice
        const text = notice.text.trim()
        if (!notice.key || !ConnectionAlerts.noticeKeys.has(notice.key) || text === '') return
        this.send({ kind: 'credits', title: AlertTitle.credits, body: text, isBotChat: false, isActiveChat: false, isOnScreen: false })
        return
      }
      default:
        return
    }
  }

  private raiseForRequest(request: ServerRequest): void {
    if (request.replayed) return
    const sid = requestSessionID(request) ?? ''
    const kind = requestKind(request)
    switch (kind.kind) {
      case 'approval': {
        const approval = kind.approval
        const text = approval.command?.trim() || approval.description?.trim() || 'A command needs approval.'
        this.send({ ...this.chatAlert('approval', AlertTitle.approval, sid, alertBody(text, text)), requestID: request.id })
        return
      }
      case 'clarify':
        this.send(this.chatAlert('input', AlertTitle.input, sid, alertBody(kind.clarify.questions[0]?.question, inputBody)))
        return
      case 'sudo': case 'secret':
        this.send(this.chatAlert('input', AlertTitle.input, sid, inputBody))
        return
      case 'unsupported':
        return
    }
  }

  /** A background process of `chat` finished, as Desktop notifies one (`composer-status.ts:333-362`). */
  backgroundFinished(chat: ChatSession, process: BackgroundProcess): void {
    if (!this.sink) return
    const title = process.state === 'failed' ? AlertTitle.backgroundFailed : AlertTitle.backgroundDone
    this.send(this.chatAlert('backgroundDone', title, chat.sessionID, backgroundAlertBody(process)))
  }

  /** An alert about the chat on runtime session `sid` (the active chat when empty). */
  private chatAlert(kind: AlertKind, title: string, sid: string, body: string): GatewayAlert {
    const active = this.host.active
    const chat = sid === '' || active?.sessionID === sid ? active : this.host.warm.find((each) => each.sessionID === sid)
    const isActive = chat !== undefined && chat === active
    const profile = chat?.profile
    const subtitle = this.chatLabel(chat, sid)
    const sessionID = chat?.sessionID ?? (sid === '' ? undefined : sid)
    return {
      kind, title, body,
      ...(subtitle !== undefined ? { subtitle } : {}),
      ...(sessionID !== undefined ? { sessionID } : {}),
      ...(chat?.storedSessionID !== undefined ? { storedSessionID: chat.storedSessionID } : {}),
      ...(profile !== undefined ? { profile } : {}),
      isBotChat: chat?.kind === 'botChat',
      isActiveChat: isActive,
      isOnScreen: isActive && this.isChatOnScreen,
    }
  }

  /** The chat as the session list names it: a Bot Chat by its bot, a side chat by its title; else the bot, else the id's tail. */
  private chatLabel(chat: ChatSession | undefined, sid: string): string | undefined {
    const bot = chat?.profile !== undefined ? this.host.bots.find((each) => each.name === chat.profile) : undefined
    if (chat) {
      if (chat.kind === 'botChat' && bot) return bot.displayName
      const title = chat.title?.trim()
      if (title) return title
      if (chat.storedSessionID && chat.profile !== undefined) {
        const row = this.host.sessionRow(chat.profile, chat.storedSessionID)
        const name = (row?.title ?? row?.preview)?.trim()
        if (name) return name
      }
    }
    if (bot) return bot.displayName
    return sid === '' ? undefined : `#${sid.slice(-6)}`
  }

  private send(alert: GatewayAlert): boolean {
    return this.sink?.(alert) ?? false
  }

  // MARK: Answering from a notification

  /** Approves or rejects approval request `requestID` (a notification's button), wherever it waits. */
  answerApproval(requestID: string, choice: ApprovalChoice): void {
    const chats = [...(this.host.active ? [this.host.active] : []), ...this.host.warm]
    for (const chat of chats) {
      const request = chat.get().pendingRequests.find((each) => each.id === requestID)
      if (request) {
        chat.answerApproval(request, choice)
        return
      }
    }
    if (!this.host.otherRequests.some((request) => request.id === requestID)) return
    const client = this.host.client
    if (!client) throw new GatewayClientError('notConnected')
    client.respond(requestID, { result: { choice } })
    this.host.dropOtherRequest(requestID)
  }
}
