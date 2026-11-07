import SwiftUI

extension View {
    /// Calls `dismiss` on a click or tap anywhere in the app outside this view, which goes on
    /// to what it landed on: it watches the window, as a popover does, so it also covers the
    /// sidebar and the composer, without a layer over them that would swallow the click.
    func dismissesOnOutsideTap(_ dismiss: @escaping () -> Void) -> some View {
        modifier(OutsideTapModifier(dismiss: dismiss))
    }
}

private struct OutsideTapModifier: ViewModifier {
    let dismiss: () -> Void
    /// This view's frame in its window: read by the watcher, never drawn.
    @State private var frame = FrameBox()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame.rect = $0 }
            #if os(macOS)
            .onAppear { frame.watcher.start(frame: frame, dismiss: dismiss) }
            .onDisappear { frame.watcher.stop() }
            #else
            .background { WindowTapWatcher(frame: frame, dismiss: dismiss).allowsHitTesting(false) }
            #endif
    }
}

@MainActor
private final class FrameBox {
    var rect = CGRect.zero
    #if os(macOS)
    let watcher = OutsideClickWatcher()
    #endif
}

#if os(macOS)
@MainActor
private final class OutsideClickWatcher {
    private var monitor: Any?

    func start(frame: FrameBox, dismiss: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Local monitors run on the main thread, inside the app's event dispatch
            // (`ScrollLatching`): the event never leaves it.
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                // Global frames count down from the window's top; events up from its bottom.
                let height = event.window?.contentView?.bounds.height ?? 0
                let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                if !frame.rect.contains(point) { dismiss() }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#else
/// Puts a tap recognizer on the window, for as long as this view is in it.
private struct WindowTapWatcher: UIViewRepresentable {
    let frame: FrameBox
    let dismiss: () -> Void

    func makeUIView(context: Context) -> WatcherView {
        WatcherView(frame: frame, dismiss: dismiss)
    }

    func updateUIView(_ view: WatcherView, context: Context) {
        view.dismiss = dismiss
    }

    final class WatcherView: UIView, UIGestureRecognizerDelegate {
        private let frameBox: FrameBox
        var dismiss: () -> Void
        private lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            return tap
        }()

        init(frame: FrameBox, dismiss: @escaping () -> Void) {
            frameBox = frame
            self.dismiss = dismiss
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not from a storyboard") }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            window?.removeGestureRecognizer(tap)
            newWindow?.addGestureRecognizer(tap)
        }

        @objc private func tapped(_ tap: UITapGestureRecognizer) {
            if !frameBox.rect.contains(tap.location(in: window)) { dismiss() }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
