import Foundation
import HermesKit
import HermesProtocol
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The chat a clicked notification opens (`RootView` opens it).
struct AlertTarget: Equatable {
    var server: UUID
    var profile: String?
    var storedSessionID: String
    var isBotChat: Bool
}

/// Shows the connections' alerts (`GatewayAlert`) as system notifications, when
/// `AlertGate` lets them through, and handles clicks on them and their Approve / Reject
/// buttons, as Hermes Desktop's native notifications do
/// (`apps/desktop/src/store/native-notifications.ts`, `electron/notification-ipc.ts`).
@MainActor
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    let gate = AlertGate()
    /// Whether the app is in front: on the Mac, the active app; on iOS, the active scene.
    var appIsActive = true
    weak var model: AppModel?

    private var center: UNUserNotificationCenter { .current() }

    static let approvalCategory = "approval"
    static let approveAction = "approve"
    static let rejectAction = "reject"

    /// Takes over the app's notifications and asks for permission once.
    func install() {
        center.delegate = self
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve")
        let reject = UNNotificationAction(identifier: Self.rejectAction, title: "Reject", options: .destructive)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [approve, reject], intentIdentifiers: []),
        ])
        guard !AppModel.isUITest, gate.preferences.isEnabled else { return }
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// Shows `alert` from `server` if the gate lets it through; says whether it did.
    func show(_ alert: GatewayAlert, from server: UUID) -> Bool {
        guard gate.admit(alert, appIsActive: appIsActive) else { return false }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        if let subtitle = alert.subtitle { content.subtitle = subtitle }
        content.body = alert.body
        content.sound = .default
        // One thread per chat, as Messages groups a conversation's notifications.
        content.threadIdentifier = "\(server.uuidString)/\(alert.profile ?? "")/\(alert.storedSessionID ?? alert.sessionID ?? "")"
        var info: [String: Any] = ["server": server.uuidString, "isBotChat": alert.isBotChat]
        if let profile = alert.profile { info["profile"] = profile }
        if let stored = alert.storedSessionID { info["stored"] = stored }
        if let request = alert.requestID, alert.kind == .approval {
            info["request"] = request
            content.categoryIdentifier = Self.approvalCategory
        }
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return true
    }

    /// Settings' "Send Test Notification": past the gate. Says whether it was allowed.
    func sendTest() async -> Bool {
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Talaria"
        content.body = "Notifications are working."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    /// Whether the system lets the app show notifications at all.
    func isAuthorized() async -> Bool? {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: nil
        case .denied: false
        default: true
        }
    }

    /// The system's notification settings for this app.
    static var systemSettingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
        #else
        URL(string: UIApplication.openNotificationSettingsURLString)
        #endif
    }

    // MARK: UNUserNotificationCenterDelegate

    /// In front, the gate already decided (a prompt for a chat not on screen): show it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let server = (info["server"] as? String).flatMap(UUID.init(uuidString:))
        let profile = info["profile"] as? String
        let stored = info["stored"] as? String
        let isBotChat = info["isBotChat"] as? Bool ?? false
        let request = info["request"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let model, let server else { return }
            switch action {
            case Self.approveAction, Self.rejectAction:
                guard let request else { return }
                let choice: ApprovalChoice = action == Self.approveAction ? .once : .deny
                Task { await model.answerApproval(request, choice: choice, on: server) }
            case UNNotificationDefaultActionIdentifier:
                #if os(macOS)
                NSApp.activate()
                #endif
                guard let stored else { return }
                model.alertTarget = AlertTarget(server: server, profile: profile, storedSessionID: stored, isBotChat: isBotChat)
            default:
                break
            }
        }
    }
}
