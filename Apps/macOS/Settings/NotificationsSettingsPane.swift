import HermesKit
import SwiftUI

/// The Notifications tab: the same settings as `NotificationsSettingsView` (iOS), as a
/// columns form.
struct NotificationsSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Notifications:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(NotificationSettingsCopy.enableAll, isOn: model.alertsEnabled)
                        .accessibilityIdentifier("notifications.enabled")
                    SettingsNote(LocalizedStringKey(NotificationSettingsCopy.enableAllNote))
                }
            }

            LabeledContent("In the app:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(NotificationSettingsCopy.inApp, isOn: model.alertsInApp)
                        .accessibilityIdentifier("notifications.inApp")
                        .disabled(!model.alertPreferences.isEnabled)
                    SettingsNote(LocalizedStringKey(NotificationSettingsCopy.inAppNote))
                }
            }

            LabeledContent("Notify when:") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AlertKind.allCases, id: \.self) { kind in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(NotificationSettingsCopy.label(kind), isOn: model.alertSwitch(kind))
                                .accessibilityIdentifier("notifications.\(kind.rawValue)")
                            SettingsNote(LocalizedStringKey(NotificationSettingsCopy.note(kind)))
                                .padding(.leading, 20)
                        }
                    }
                    .disabled(!model.alertPreferences.isEnabled)
                }
            }

            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    NotificationTestRow()
                    SettingsNote(LocalizedStringKey(NotificationSettingsCopy.hint))
                }
            } label: {
                EmptyView()
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: MacSettingsView.paneWidth)
    }
}
