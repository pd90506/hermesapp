import SwiftUI

/// The macOS Settings window, laid out like the system apps' (Mail, Safari): a toolbar of
/// icon-and-label tabs, and under each a form with right-aligned labels. Every tab has
/// the same width, so the tabs in the toolbar stay put; the window takes the height of the
/// tab shown, and its title follows the tab.
struct MacSettingsView: View {
    /// The width of every tab (the Servers tab's list and details need it all).
    static let paneWidth: CGFloat = 760

    var body: some View {
        TabView {
            Tab("Servers", systemImage: "server.rack") {
                ServersSettingsPane()
            }
            Tab("Session Sources", systemImage: "tray.2") {
                SessionSourcesSettingsPane()
            }
            Tab("Appearance", systemImage: "paintpalette") {
                AppearanceSettingsPane()
            }
            Tab("Markdown", systemImage: "textformat") {
                MarkdownSettingsPane()
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
            .uiFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
