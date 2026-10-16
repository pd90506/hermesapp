#if os(macOS)
import AppKit
import SwiftUI

/// Reports where the view it backs is in its window, in the window's coordinates
/// (origin at the bottom left), whenever that changes.
///
/// For lining up views in different hosting views: SwiftUI's `.global` space is the
/// hosting view's, and each title bar item has a hosting view of its own. It also
/// reports a move with no change in its own size, such as the toolbar sliding an item
/// along, by watching every view it is inside.
struct WindowFrameReader: NSViewRepresentable {
    let onChange: @MainActor (CGRect) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (CGRect) -> Void)?
        private var reported: CGRect?
        private var observers: [NSObjectProtocol] = []

        // Never in the way of clicks or the pointer.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            reported = nil
            guard window != nil else { return }
            var view: NSView? = self
            while let current = view {
                current.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: current, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
                view = current.superview
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard window != nil, onChange != nil else { return }
            let frame = convert(bounds, to: nil)
            guard frame != reported else { return }
            reported = frame
            // After the update in progress: this changes view state.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onChange?(frame) }
            }
        }
    }
}
#endif
