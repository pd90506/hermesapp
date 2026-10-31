import Foundation

/// What a system notification is about. The first six are Hermes Desktop's native
/// notification kinds (`NativeNotificationKind`,
/// `apps/desktop/src/store/native-notifications.ts:26-37`; its seventh, `plugin`, is for
/// desktop plugins, which this app has none of). `otherReply` is this app's own.
public enum AlertKind: String, CaseIterable, Codable, Sendable {
    /// A command waits for the user to approve or reject it.
    case approval
    /// Hermes asked a question, or needs a password or a secret.
    case input
    /// A turn finished in the chat on screen while the app was away.
    case turnDone
    /// A turn failed in the chat on screen while the app was away.
    case turnError
    /// A `/background` task finished.
    case backgroundDone
    /// Credits access paused or restored (`credits.*` notices).
    case credits
    /// A reply came in another chat (`[client choice]`, off by default): one this app
    /// sees only in its session list, such as a Telegram or cron session's.
    case otherReply

    /// Blocking prompts: they break through even while the app is in front, when they
    /// are for a chat that isn't on screen (`ATTENTION_KINDS`, `native-notifications.ts:39-40`).
    public var isAttention: Bool { self == .approval || self == .input }

    var isOnByDefault: Bool { self != .otherReply }
}

/// Which system notifications the user wants, on this device. Desktop keeps the same
/// switches per device (`hermes:native-notifications`, `native-notifications.ts:47-61`).
public struct AlertPreferences: Sendable, Hashable, Codable {
    /// Off silences every kind.
    public var isEnabled = true
    /// While the app is in front, banners for chats not on screen too (`[client choice]`,
    /// the user, 2026-10-31): Desktop shows those as in-app toasts instead.
    public var showsInApp = true
    /// Kinds switched away from their default, by raw value.
    private var kinds: [String: Bool] = [:]

    public init() {}

    public func isOn(_ kind: AlertKind) -> Bool {
        isEnabled && (kinds[kind.rawValue] ?? kind.isOnByDefault)
    }

    /// The kind's own switch, whatever `isEnabled` says.
    public func kindSwitch(_ kind: AlertKind) -> Bool { kinds[kind.rawValue] ?? kind.isOnByDefault }

    public mutating func set(_ kind: AlertKind, on: Bool) { kinds[kind.rawValue] = on }

    private enum CodingKeys: String, CodingKey { case isEnabled, showsInApp, kinds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showsInApp = try container.decodeIfPresent(Bool.self, forKey: .showsInApp) ?? true
        kinds = try container.decodeIfPresent([String: Bool].self, forKey: .kinds) ?? [:]
    }
}

/// A system notification a connection would show (`GatewayConnection.alertSink`); the
/// app decides with `AlertGate` whether it does.
public struct GatewayAlert: Sendable, Hashable {
    public var kind: AlertKind
    public var title: String
    /// The chat it is about, by name.
    public var subtitle: String?
    public var body: String
    /// The runtime session it came from, if any.
    public var sessionID: String?
    /// The chat to open when the notification is clicked, if known.
    public var storedSessionID: String?
    public var profile: String?
    public var isBotChat = false
    /// The chat is its connection's active one (on screen, or the last one shown).
    public var isActiveChat = false
    /// The chat is on screen: active, and its column in view.
    public var isOnScreen = false
    /// An approval's server request id, for the notification's Approve / Reject.
    public var requestID: String?

    public init(kind: AlertKind, title: String, subtitle: String? = nil, body: String, sessionID: String? = nil,
                storedSessionID: String? = nil, profile: String? = nil, isBotChat: Bool = false,
                isActiveChat: Bool = false, isOnScreen: Bool = false, requestID: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sessionID = sessionID
        self.storedSessionID = storedSessionID
        self.profile = profile
        self.isBotChat = isBotChat
        self.isActiveChat = isActiveChat
        self.isOnScreen = isOnScreen
        self.requestID = requestID
    }

    /// Desktop's titles (`notifications.native`, `apps/desktop/src/i18n/en.ts:473-487`).
    enum Title {
        static let approval = "Approval needed"
        static let input = "Input needed"
        static let turnDone = "Hermes finished"
        static let turnError = "Turn failed"
        static let backgroundDone = "Background task finished"
        static let credits = "Credits"
        static let otherReply = "New reply"
    }

    /// Desktop's fallback body when a reply has no text (`turnDoneBody`).
    static let turnDoneBody = "Message complete."
    static let inputBody = "Hermes is waiting for your response."

    /// A reply's text as a body: trimmed, at most 140 characters, else the fallback
    /// (`turnDoneNotificationBody`, `apps/desktop/src/lib/turn-done-notification-body.ts`).
    static func body(_ text: String?, fallback: String = turnDoneBody) -> String {
        let reply = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = reply.isEmpty ? fallback : reply
        return source.count <= 140 ? source : String(source.prefix(140))
    }
}

/// Whether an alert is shown, as Desktop decides (`shouldFire` and `throttled`,
/// `native-notifications.ts:111-158`):
/// - kinds the user switched off never show;
/// - credits notices are not about one chat: they show whenever the app is away;
/// - approvals and questions show while the app is away, or for a chat not on screen;
/// - finished and failed turns show only for the active chat, only while the app is away,
///   so a busy gateway can't raise one per background session;
/// - replies in other chats (`otherReply`) show only while the app is away;
/// - with `showsInApp`, while the app is in front, finished and failed turns,
///   `/background` tasks and other replies also show for any chat not on screen, as a
///   banner that opens it;
/// - the same kind for the same chat shows at most once a second (replayed events).
@MainActor
public final class AlertGate {
    public var preferences: AlertPreferences
    static let throttle: TimeInterval = 1
    private var lastShown: [String: Date] = [:]

    public init(preferences: AlertPreferences = AlertPreferences()) {
        self.preferences = preferences
    }

    /// Whether to show `alert`, `appIsActive` saying whether the app is in front. A
    /// `true` counts toward the throttle.
    public func admit(_ alert: GatewayAlert, appIsActive: Bool, now: Date = .now) -> Bool {
        guard preferences.isOn(alert.kind) else { return false }
        let fires: Bool
        switch alert.kind {
        case .credits: fires = !appIsActive
        case .approval, .input: fires = !appIsActive || !alert.isOnScreen
        case .turnDone, .turnError, .backgroundDone, .otherReply:
            if appIsActive {
                fires = preferences.showsInApp && !alert.isOnScreen
            } else {
                fires = alert.kind == .otherReply || alert.isActiveChat
            }
        }
        guard fires else { return false }
        lastShown = lastShown.filter { now.timeIntervalSince($0.value) < Self.throttle }
        let key = "\(alert.kind.rawValue):\(alert.sessionID ?? alert.storedSessionID ?? "")"
        guard lastShown[key] == nil else { return false }
        lastShown[key] = now
        return true
    }
}
