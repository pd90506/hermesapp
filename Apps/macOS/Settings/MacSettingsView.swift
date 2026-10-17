import SwiftUI

/// The macOS Settings window, laid out like the system apps' (Mail, Safari): a toolbar of
/// icon-and-label tabs, and under each a form with right-aligned labels. The window takes
/// the size of the tab shown and its title follows the tab.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("Servers", systemImage: "server.rack") {
                ServersSettingsPane()
            }
            Tab("Session Sources", systemImage: "tray.2") {
                SessionSourcesSettingsPane()
            }
        }
    }
}

/// Footnotes under a row of a columns form, in the trailing column.
struct SettingsNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
