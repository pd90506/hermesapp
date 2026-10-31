#if os(iOS)
import HermesKit
import SwiftUI

/// Settings ▸ Notifications on iOS; the macOS Settings window has `NotificationsSettingsPane`.
struct NotificationsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ThemedForm {
            Section {
                Toggle(NotificationSettingsCopy.enableAll, isOn: model.alertsEnabled)
                    .accessibilityIdentifier("notifications.enabled")
            } footer: {
                Text(NotificationSettingsCopy.enableAllNote)
            }
            Section {
                Toggle(NotificationSettingsCopy.inApp, isOn: model.alertsInApp)
                    .accessibilityIdentifier("notifications.inApp")
                    .disabled(!model.alertPreferences.isEnabled)
            } footer: {
                Text(NotificationSettingsCopy.inAppNote.replacingOccurrences(of: "Click", with: "Tap"))
            }
            Section {
                ForEach(AlertKind.allCases, id: \.self) { kind in
                    Toggle(isOn: model.alertSwitch(kind)) {
                        Text(NotificationSettingsCopy.label(kind))
                        Text(NotificationSettingsCopy.note(kind))
                    }
                    .accessibilityIdentifier("notifications.\(kind.rawValue)")
                }
                .disabled(!model.alertPreferences.isEnabled)
            } header: {
                Text("Notify When")
            }
            Section {
                NotificationTestRow()
            } footer: {
                Text(NotificationSettingsCopy.hint)
            }
        }
        .navigationTitle("Notifications")
    }
}
#endif
