import HermesKit
import SwiftUI

/// Settings ▸ Notifications, both apps: the switches of Hermes Desktop's Notifications page
/// (`apps/desktop/src/app/settings/notifications-settings.tsx`, its copy in
/// `i18n/en_notifications.ts`), plus Replies in Other Chats.
enum NotificationSettingsCopy {
    static let enableAll = "Enable Notifications"
    static let enableAllNote = "Off silences every notification below. Kept on this device only."
    static let inApp = "Banners While Talaria Is Open"
    static let inAppNote = "Responses, failures and replies in chats you aren't looking at show as a banner too while Talaria is in front. Click one to open its chat."

    static func label(_ kind: AlertKind) -> String {
        switch kind {
        case .approval: "Approval Needed"
        case .input: "Input Needed"
        case .turnDone: "Response Ready"
        case .turnError: "Turn Failed"
        case .backgroundDone: "Background Task Finished"
        case .credits: "Credit Alerts"
        case .otherReply: "Replies in Other Chats"
        }
    }

    static func note(_ kind: AlertKind) -> String {
        switch kind {
        case .approval: "A command is waiting for you to approve or reject it."
        case .input: "Hermes asked a question, or needs a password or secret."
        case .turnDone: "A turn finished in a chat you aren't looking at."
        case .turnError: "A turn failed in a chat you aren't looking at."
        case .backgroundDone: "A /background task finished."
        case .credits: "Credit access is paused or restored."
        case .otherReply: "A reply came in a chat Talaria doesn't follow live, such as a Telegram or cron session."
        }
    }

    /// Desktop's `focusedHint`, with what iOS allows.
    static var hint: String {
        #if os(iOS)
        "While Talaria is in the background, responses and failures notify only for the chat you had open, as in Hermes Desktop. With banners off, the same holds while it is open. iOS lets Talaria run for about 30 seconds after you leave it; after that, it checks for replies only when iOS wakes it for Background App Refresh, which can be many minutes or hours apart. Approvals and questions that come while it is suspended show when you return."
        #else
        "While Talaria is in the background, responses and failures notify only for the chat you had open, as in Hermes Desktop. With banners off, the same holds while it is open."
        #endif
    }

    static let testSent = "Test sent. If nothing appears, check Focus or Do Not Disturb."
    static let denied = "Notifications for Talaria are off in System Settings."
}

/// The test button and the system permission's state, under the switches.
struct NotificationTestRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var result: String?
    @State private var isAuthorized: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Send Test Notification") {
                Task {
                    let sent = await model.notifier.sendTest()
                    isAuthorized = await model.notifier.isAuthorized()
                    result = sent ? NotificationSettingsCopy.testSent : NotificationSettingsCopy.denied
                }
            }
            .accessibilityIdentifier("notifications.test")
            if isAuthorized == false {
                Button("Open System Settings") {
                    if let url = SystemNotifier.systemSettingsURL { openURL(url) }
                }
            }
            if let result {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { isAuthorized = await model.notifier.isAuthorized() }
    }
}

extension AppModel {
    /// A kind's switch, as Settings shows it: off while all are off.
    func alertSwitch(_ kind: AlertKind) -> Binding<Bool> {
        Binding(
            get: { self.alertPreferences.isOn(kind) },
            set: { self.alertPreferences.set(kind, on: $0) })
    }

    var alertsInApp: Binding<Bool> {
        Binding(
            get: { self.alertPreferences.isEnabled && self.alertPreferences.showsInApp },
            set: { self.alertPreferences.showsInApp = $0 })
    }

    var alertsEnabled: Binding<Bool> {
        Binding(
            get: { self.alertPreferences.isEnabled },
            set: { self.alertPreferences.isEnabled = $0 })
    }
}
