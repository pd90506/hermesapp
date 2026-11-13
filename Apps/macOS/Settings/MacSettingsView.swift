import SwiftUI

/// The macOS Settings window, laid out like the system apps' (Mail, Safari): a toolbar of
/// icon-and-label tabs, and under each a form with right-aligned labels. Every tab has
/// the same width, so the tabs in the toolbar stay put; the window takes the height of the
/// tab shown, and its title follows the tab.
struct MacSettingsView: View {
    /// The width of every tab (the Servers tab's list and details need it all).
    static let paneWidth: CGFloat = 760

    /// The tabs, in the toolbar's order.
    enum Pane: String { case servers, providers, capabilities, sessionSources, appearance, notifications }

    /// The tab shown, kept across launches as the TabView kept it on its own.
    @AppStorage("settingsPane") private var pane: Pane = .servers
    /// The height each tab is given, once it has been measured. The window takes the
    /// height of the tab shown, so this is what resizes it.
    @State private var heights: [Pane: CGFloat] = [:]

    var body: some View {
        // The window follows the shown tab's height. Changed inside an animation, that
        // height resizes the window smoothly; changed outside one, the window jumps (macOS 26, `windowResizeAnchor(_:)`'s
        // documentation: drive window animations by changing the size of a view).
        TabView(selection: Binding(get: { pane }, set: { select($0) })) {
            Tab("Servers", systemImage: "server.rack", value: Pane.servers) {
                sized(.servers) { ServersSettingsPane() }
            }
            Tab("Providers", systemImage: "key", value: Pane.providers) {
                sized(.providers) {
                    ProvidersView()
                        .frame(width: Self.paneWidth, height: 600)
                }
            }
            Tab("Capabilities", systemImage: "puzzlepiece.extension", value: Pane.capabilities) {
                sized(.capabilities) {
                    CapabilitiesView()
                        .padding(20)
                        .frame(width: Self.paneWidth)
                }
            }
            Tab("Session Sources", systemImage: "tray.2", value: Pane.sessionSources) {
                sized(.sessionSources) { SessionSourcesSettingsPane() }
            }
            Tab("Appearance", systemImage: "paintpalette", value: Pane.appearance) {
                sized(.appearance) { AppearanceSettingsPane() }
            }
            Tab("Notifications", systemImage: "bell.badge", value: Pane.notifications) {
                sized(.notifications) { NotificationsSettingsPane() }
            }
            // The Markdown tab (`MarkdownSettingsPane`, a colour per element) is hidden for
            // now (user, 2026-10): the theme in Appearance sets the Markdown colours.
        }
    }

    /// Shows `new`. Its height (when it has been shown before) changes in the same
    /// animation, so the window resizes smoothly to it. A tab not shown before starts at
    /// the window's height, so the window doesn't jump to it when its content comes (a
    /// tab can take a moment to build the first time); `sized` then animates to it.
    private func select(_ new: Pane) {
        guard new != pane else { return }
        if heights[new] == nil, let current = heights[pane] { heights[new] = current }
        withAnimation(Self.resize) { pane = new }
    }

    /// The window's resize: short, so a tab change feels immediate.
    private static let resize = Animation.easeInOut(duration: 0.2)

    /// A tab at its own height, measured, and given that height through `heights`: the
    /// first measure as it is, a later change (a tab whose content grows after it shows,
    /// or a text size changed) in an animation, so the window follows smoothly. Only the
    /// window animates: the tab's content shows at once, as in AppKit's preference
    /// windows, rather than fading and sliding into place with the resize.
    private func sized(_ tab: Pane, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .transaction { $0.animation = nil }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard let old = heights[tab] else { heights[tab] = height; return }
                guard abs(old - height) >= 0.5 else { return }
                if tab == pane {
                    withAnimation(Self.resize) { heights[tab] = height }
                } else {
                    heights[tab] = height
                }
            }
            .frame(height: heights[tab], alignment: .top)
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
