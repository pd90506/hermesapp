import AppKit
import HermesKit
import SwiftUI

/// One continuous themed sidebar, with native window controls above the rail and list.
/// The chat occupies its own flat column from the window's top to its bottom.
struct WindowLayout<Rail: View, List: View, Chat: View>: View {
    @ViewBuilder var rail: Rail
    @ViewBuilder var list: List
    @ViewBuilder var chat: Chat

    @Environment(\.surfaces) private var surfaces
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("profileRailShown") private var isRailShown = true
    // A separate layout preference leaves the previous sidebar width untouched while
    // existing installs see the compact default. Subsequent drags persist normally.
    @AppStorage("compactSessionListWidth") private var listWidth = 260.0
    /// The window buttons, in the window (top-left origin); nil in full screen, where
    /// they aren't in the window.
    @State private var windowButtons: CGRect?

    static var listWidths: ClosedRange<Double> { 220...360 }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if isRailShown {
                        rail
                            .padding(.top, headerHeight)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
                                    .padding(.top, headerHeight)
                            }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    list
                        .frame(width: CGFloat(listWidth.clamped(to: Self.listWidths)))
                }
            }
            .background(surfaces.chrome)
            .overlay(alignment: .trailing) {
                ColumnResizer(width: $listWidth, range: Self.listWidths)
            }
            Rectangle().fill(.primary.opacity(0.12)).frame(width: 1)
            chat
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .backgroundStyle(surfaces.chat)
                .background(surfaces.chat)
        }
        // Preserve the existing rail's transition and the space it releases to chat.
        .animation(Motion.rail(reduceMotion: reduceMotion), value: isRailShown)
        .environment(\.profileRailVisibility, $isRailShown)
        // Header geometry is measured in this same window-content coordinate space,
        // so native control clearance follows the actual list position during collapse.
        .environment(\.nativeButtonsTrailing, windowButtons?.maxX ?? 78)
        .environment(\.windowHeaderHeight, headerHeight)
        .coordinateSpace(name: "mainWindowContent")
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowButtonsReader { windowButtons = $0 })
        .toolbar(removing: .title)
        // No toolbar background: the themed columns show through (macOS 26 also showed one
        // only under the pointer).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// The window's top band: the window buttons, the sidebar's header and the chat's title
    /// on one line through its middle. As tall as a toolbar's title bar (the App Store's,
    /// #54): with no toolbar the title bar is 32 pt and the band was cramped against the
    /// window's top edge (the user, 2026-10-21). The window buttons are moved down to its
    /// middle (`WindowButtonsReader`), as Hermes Desktop places them on its title bar.
    static var headerHeight: CGFloat { 52 }

    /// As tall again below the window buttons as above them; the band's own height in
    /// full screen, where they aren't in the window.
    private var headerHeight: CGFloat {
        windowButtons.map { min(max(($0.midY * 2).rounded(), 32), 64) } ?? Self.headerHeight
    }

}

/// Hides or shows the profile rail, after the window buttons (⌃⌘S, the system's sidebar
/// shortcut), as Slack's toggle hides its workspaces (the user, 2026-10-18: the profiles,
/// not the sessions). Shown again, it is the way to switch profiles.
struct CollapseButton: View {
    @Binding var isRailShown: Bool

    var body: some View {
        Button(isRailShown ? "Hide Profiles" : "Show Profiles", systemImage: "sidebar.left") {
            // Animated by `WindowLayout`.
            isRailShown.toggle()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .hoverButtonStyle(padding: 5)
        .help(isRailShown ? "Hide the profiles" : "Show the profiles")
        .keyboardShortcut("s", modifiers: [.control, .command])
        // A window control, as the window buttons beside it: never the key view, so no
        // focus ring around it at launch.
        .focusable(false)
        .accessibilityIdentifier("collapseProfiles")
    }
}

/// The session list's trailing edge, against the chat: drags to resize the list.
private struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// The width when the drag began.
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let from = start ?? width.clamped(to: range)
                        start = from
                        width = (from + value.translation.width).clamped(to: range)
                    }
                    .onEnded { _ in start = nil })
            // Straddle the sidebar/chat boundary.
            .offset(x: 4)
            .accessibilityHidden(true)
    }
}

/// Reports where the window buttons are, in the window with a top-left origin, as the
/// window resizes or leaves full screen; nil in full screen, where they aren't in it.
private struct WindowButtonsReader: NSViewRepresentable {
    let onChange: @MainActor (CGRect?) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (CGRect?) -> Void)?
        private var reported: CGRect??
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            reported = nil
            guard let window else { return }
            // Keep AppKit's real titlebar and standard buttons above full-size content.
            // No replacement traffic lights or toolbar material: the SwiftUI columns
            // paint all the way to the top while AppKit retains native window dragging.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = nil
            if !window.styleMask.contains(.fullScreen) {
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(type)?.isHidden = false
                }
            }
            // AppKit lays its title bar out again (a resize, full screen, key changes):
            // the buttons go back to its top each time, so they're moved down again.
            if let container = Self.titlebarContainer(of: window) {
                container.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: container, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window else { return }
            placeButtons(in: window)
            var frame: CGRect?
            if !window.styleMask.contains(.fullScreen) {
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    guard let button = window.standardWindowButton(type), !button.isHidden,
                          let superview = button.superview else { continue }
                    let inWindow = superview.convert(button.frame, to: nil)
                    let flipped = CGRect(x: inWindow.minX, y: window.frame.height - inWindow.maxY,
                                         width: inWindow.width, height: inWindow.height)
                    frame = frame.map { $0.union(flipped) } ?? flipped
                }
            }
            guard onChange != nil, reported != .some(frame) else { return }
            reported = .some(frame)
            // After the update in progress: this changes view state.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onChange?(frame) }
            }
        }

        /// The view holding the title bar and its window buttons (AppKit's
        /// `NSTitlebarContainerView`), along the window's top.
        static func titlebarContainer(of window: NSWindow) -> NSView? {
            guard let close = window.standardWindowButton(.closeButton) else { return nil }
            var view = close.superview
            while let candidate = view {
                if String(describing: type(of: candidate)).contains("TitlebarContainer") { return candidate }
                view = candidate.superview
            }
            return close.superview?.superview
        }

        /// The title bar as tall as the window's top band, and the window buttons in its
        /// middle, where they were left of it: as Electron's `trafficLightPosition`, which
        /// Hermes Desktop uses, it grows AppKit's title bar container to the band and moves
        /// the buttons down in it. Taller, the title bar still lets clicks through to the
        /// sidebar's header under it, as it did at its own height. Left alone in full
        /// screen, where the title bar slides down from the top on its own.
        private func placeButtons(in window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let container = Self.titlebarContainer(of: window),
                  let row = close.superview else { return }
            let height = WindowLayout<EmptyView, EmptyView, EmptyView>.headerHeight
            let top = window.frame.height
            if container.frame.height != height || container.frame.maxY != top {
                let old = container.frame.height
                container.frame = NSRect(x: container.frame.minX, y: top - height,
                                         width: container.frame.width, height: height)
                // The views between it and the buttons that filled it fill it still.
                var path: [NSView] = []
                var view: NSView? = row
                while let inner = view, inner !== container { path.insert(inner, at: 0); view = inner.superview }
                for inner in path where inner.frame.height == old {
                    inner.frame = NSRect(x: inner.frame.minX, y: 0, width: inner.frame.width,
                                         height: inner.superview?.bounds.height ?? height)
                }
            }
            if row.frame.height >= height {
                // The buttons straight on the title bar: each in its middle.
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    guard let button = window.standardWindowButton(type) else { continue }
                    let y = ((row.bounds.height - button.frame.height) / 2).rounded()
                    if button.frame.minY != y { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
                }
            } else if let parent = row.superview {
                // The buttons in a group of their own: the group in the middle.
                let y = ((parent.bounds.height - row.frame.height) / 2).rounded()
                if row.frame.minY != y { row.setFrameOrigin(NSPoint(x: row.frame.minX, y: y)) }
            }
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}

extension EnvironmentValues {
    @Entry var nativeButtonsTrailing: CGFloat = 78
    @Entry var profileRailVisibility: Binding<Bool> = .constant(true)
    @Entry var windowHeaderHeight: CGFloat = 52
}
