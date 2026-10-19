import AppKit
import HermesKit
import SwiftUI

/// The Mac window, as Slack's: a frame along the top (the window buttons and the
/// profile rail's collapse button on it) and down the profile rail, in a deeper tint of
/// the theme (`ThemeSurfaces.frame`), around a panel rounded at its top-leading corner,
/// on the theme's chrome: the session list, and the chat as a card set in from the
/// window's edges, as Hermes Desktop lays its transcript on the sidebar's colour. The
/// frame was the accent's deep shade; the user asked for a calmer look, with the
/// profiles still standing apart (2026-10-19).
///
/// The title bar shows no background and no title: the strip under it is the frame's,
/// as tall as the title bar (centred on the window buttons). The collapse button is the
/// title bar's own item after the window buttons, so the title bar still drags the window
/// and takes clicks as it does (a button drawn under it, with no title bar, got none).
struct WindowLayout<Rail: View, List: View, Chat: View>: View {
    @ViewBuilder var rail: Rail
    @ViewBuilder var list: List
    @ViewBuilder var chat: Chat

    @Environment(\.surfaces) private var surfaces
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("profileRailShown") private var isRailShown = true
    @AppStorage("sessionListWidth") private var listWidth = 320.0
    /// The window buttons, in the window (top-left origin); nil in full screen, where
    /// they aren't in the window.
    @State private var windowButtons: CGRect?

    static var listWidths: ClosedRange<Double> { 260...480 }
    /// The card's corners: concentric with the window's, set in `cardInset` from them.
    static var cardRadius: CGFloat { 12 }
    /// How far the card is set in from the window's trailing and bottom edges.
    static var cardInset: CGFloat { 8 }

    var body: some View {
        VStack(spacing: 0) {
            strip
            HStack(spacing: 0) {
                if isRailShown {
                    rail
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                panel
            }
            // The rail slides out (in) and the panel with it, in one motion. Here, not in
            // the button: the toggle comes from the title bar's own item (and its ⌃⌘S),
            // whose `withAnimation` didn't reach this view, so the panel jumped.
            .animation(Motion.rail(reduceMotion: reduceMotion), value: isRailShown)
        }
        .background(surfaces.frame)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowButtonsReader { windowButtons = $0 })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CollapseButton(isRailShown: $isRailShown)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        // No toolbar background: the frame shows through (macOS 26 also showed one
        // only under the pointer).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// Under the title bar: as tall again below the window buttons as above them.
    private var strip: some View {
        let height = windowButtons.map { min(max(($0.midY * 2).rounded(), 32), 64) } ?? 52
        return Color.clear.frame(height: height)
    }

    /// The session list and the chat's card, on the chrome. The card is set in from the
    /// panel's top as from the window's edges; the list's header stays level with its title.
    private var panel: some View {
        HStack(spacing: 0) {
            list
                .frame(width: CGFloat(listWidth.clamped(to: Self.listWidths)))
                .overlay(alignment: .trailing) {
                    ColumnResizer(width: $listWidth, range: Self.listWidths)
                }
            card
        }
        .padding(.top, Self.cardInset)
        .background(surfaces.chrome)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.cardRadius, style: .continuous))
    }

    /// The chat on its card: a hairline edge, and in light mode a soft shadow, lift it
    /// off the chrome. Views in it that paint `.background` paint the card's colour.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
        return chat
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .backgroundStyle(surfaces.chat)
            .background(surfaces.chat)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(colorScheme == .dark ? 0.1 : 0.07), lineWidth: 1) }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 3, y: 1)
            .padding(.trailing, Self.cardInset)
            .padding(.bottom, Self.cardInset)
    }
}

/// Hides or shows the profile rail, after the window buttons (⌃⌘S, the system's sidebar
/// shortcut), as Slack's toggle hides its workspaces (the user, 2026-10-18: the profiles,
/// not the sessions). Shown again, it is the way to switch profiles.
private struct CollapseButton: View {
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

/// The session list's trailing edge, against the chat's card: drags to resize the list.
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
                        let from = start ?? width
                        start = from
                        width = (from + value.translation.width).clamped(to: range)
                    }
                    .onEnded { _ in start = nil })
            // Over the list's edge and the card's.
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
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
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
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
