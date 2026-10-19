import AppKit
import HermesKit
import SwiftUI

/// The Mac window as Slack's (asked for by the user, 2026-10-18): a frame in the theme's
/// deep colour (`ColorTheme.frameColor`), a strip along the top, with the window buttons
/// and the profile rail's collapse button, and the profile rail down the leading edge,
/// around one panel, rounded at its top-leading corner, that holds the session list and
/// the chat. It was Mail's: one glass sidebar for the rail and the list, the window
/// buttons on it.
///
/// The title bar shows no background and no title: the strip under it is the frame's, as
/// tall as the title bar (centred on the window buttons). The collapse button is the
/// title bar's own item after the window buttons, so the title bar still drags the window
/// and takes clicks as it does (a button drawn under it, with no title bar, got none).
/// The rail is drawn dark, so its marks are white on any theme.
struct WindowLayout<Rail: View, List: View, Chat: View>: View {
    /// The frame's colour.
    let color: Color
    @ViewBuilder var rail: Rail
    @ViewBuilder var list: List
    @ViewBuilder var chat: Chat

    @AppStorage("profileRailShown") private var isRailShown = true
    @AppStorage("sessionListWidth") private var listWidth = 320.0
    /// The window buttons, in the window (top-left origin); nil in full screen, where
    /// they aren't in the window.
    @State private var windowButtons: CGRect?

    static var listWidths: ClosedRange<Double> { 260...480 }

    var body: some View {
        VStack(spacing: 0) {
            strip
            HStack(spacing: 0) {
                if isRailShown {
                    rail
                        .environment(\.colorScheme, .dark)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                panel
            }
        }
        .background(color)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowButtonsReader { windowButtons = $0 })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CollapseButton(isRailShown: $isRailShown)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        // No toolbar background: the frame's colour shows through (macOS 26 also showed
        // one only under the pointer).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// Under the title bar: as tall again below the window buttons as above them.
    private var strip: some View {
        let height = windowButtons.map { min(max(($0.midY * 2).rounded(), 32), 64) } ?? 52
        return Color.clear.frame(height: height)
    }

    /// The session list and the chat, on the window's background.
    private var panel: some View {
        HStack(spacing: 0) {
            list
                .frame(width: CGFloat(listWidth.clamped(to: Self.listWidths)))
                // A touch of the frame's colour, as Slack's sidebar.
                .background(color.opacity(0.05))
            ColumnResizer(width: $listWidth, range: Self.listWidths)
            chat
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, style: .continuous))
    }
}

/// Hides or shows the profile rail, after the window buttons (⌃⌘S, the system's sidebar
/// shortcut), as Slack's toggle hides its workspaces (the user, 2026-10-18: the profiles,
/// not the sessions). Shown again, it is the way to switch profiles.
private struct CollapseButton: View {
    @Binding var isRailShown: Bool

    var body: some View {
        Button(isRailShown ? "Hide Profiles" : "Show Profiles", systemImage: "sidebar.left") {
            withAnimation(.snappy(duration: 0.25)) { isRailShown.toggle() }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15))
        // White on the frame's deep colour, as the window buttons beside it stand out.
        .foregroundStyle(.white.opacity(0.8))
        .hoverButtonStyle(padding: 5)
        .environment(\.colorScheme, .dark)
        .help(isRailShown ? "Hide the profiles" : "Show the profiles")
        .keyboardShortcut("s", modifiers: [.control, .command])
        // A window control, as the window buttons beside it: never the key view, so no
        // focus ring around it at launch.
        .focusable(false)
        .accessibilityIdentifier("collapseProfiles")
    }
}

/// The line between the session list and the chat, which drags to resize the list.
private struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// The width when the drag began.
    @State private var start: Double?

    var body: some View {
        Divider()
            .overlay {
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
            }
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

extension ColorTheme {
    /// The window's frame: the theme's (`frame`), or for Plain the system's accent
    /// deepened the same way, following it when the user picks another.
    @MainActor
    var frameColor: Color {
        if let frame { return Color(frame) }
        return Color(nsColor: NSColor(name: nil) { _ in
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            return NSColor(RGBAColor(red: accent.redComponent, green: accent.greenComponent,
                                     blue: accent.blueComponent).deepened)
        })
    }
}
