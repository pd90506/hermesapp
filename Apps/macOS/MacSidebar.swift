import SwiftUI

/// The sidebar column of the Mac window's `NavigationSplitView` (`RootView`): the profile
/// rail (it collapses) beside the session list.
///
/// The window is the system's: its toolbar, with the chat's title and the sidebar's
/// buttons; the sidebar's panel, its width and the divider the user drags; the window
/// buttons and dragging. A hand-drawn title band (#90) stretched AppKit's title bar and
/// moved the window buttons, and made AppKit ask the whole SwiftUI window for focus on
/// every frame of a scroll (Instruments, 2026-10-21); the user asked for the native
/// controls wherever there are some (2026-10-22).
struct MacSidebar<Rail: View, List: View>: View {
    @ViewBuilder var rail: Rail
    @ViewBuilder var list: List

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the rail shows. Its toggle is in the sidebar's part of the toolbar, with
    /// New chat (`SessionListView`).
    @AppStorage("profileRailShown") private var isRailShown = true

    /// The session list's widths, beside the rail when it shows.
    static var listWidths: ClosedRange<CGFloat> { 220...360 }

    var body: some View {
        HStack(spacing: 0) {
            if isRailShown {
                rail
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            list
                .frame(maxWidth: .infinity)
        }
        .animation(Motion.rail(reduceMotion: reduceMotion), value: isRailShown)
        .navigationSplitViewColumnWidth(min: railWidth + Self.listWidths.lowerBound,
                                        ideal: railWidth + 260,
                                        max: railWidth + Self.listWidths.upperBound)
        // The rail's toggle stands for the system's sidebar button: it hides the profiles,
        // not the sessions (`CollapseButton`).
        .toolbar(removing: .sidebarToggle)
    }

    private var railWidth: CGFloat { isRailShown ? ProfileRailItem.width : 0 }
}

/// Hides or shows the profile rail (⌃⌘S, the system's sidebar shortcut), as Slack's
/// toggle hides its workspaces (the user, 2026-10-18: the profiles, not the sessions).
/// Shown again, it is the way to switch profiles.
struct CollapseButton: View {
    @Binding var isRailShown: Bool

    var body: some View {
        Button(isRailShown ? "Hide Profiles" : "Show Profiles", systemImage: "sidebar.left") {
            // Animated by `MacSidebar`.
            isRailShown.toggle()
        }
        .help(isRailShown ? "Hide the profiles" : "Show the profiles")
        .keyboardShortcut("s", modifiers: [.control, .command])
        .accessibilityIdentifier("collapseProfiles")
    }
}
