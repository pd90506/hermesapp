import SwiftUI

#if os(macOS)
import AppKit

extension View {
    /// In a sheet: runs `action` when the user presses the mouse in the window the sheet
    /// is attached to, while `isEnabled`. That click is consumed, so nothing under the
    /// sheet sees it (AppKit would only beep at it anyway: the sheet is window-modal).
    ///
    /// How: an AppKit local event monitor, which sees each event the app takes from its
    /// queue before it is sent to a window, and can drop it. It acts on mouse-downs whose
    /// window is the sheet's `sheetParent` and nothing else. Typing, pasting and AutoFill
    /// are key events, or clicks in the sheet itself or in AutoFill's own panel, so they
    /// never close it.
    func onParentWindowClick(isEnabled: Bool, perform action: @escaping @MainActor () -> Void) -> some View {
        background(ParentWindowClickMonitor(isEnabled: isEnabled, action: action))
    }
}

private struct ParentWindowClickMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var action: @MainActor () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.action = action
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var isEnabled = false
        var action: @MainActor () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                // Local monitors run on the main thread, from the app's event loop.
                let parentWindowNumber = MainActor.assumeIsolated { self?.consumingWindowNumber() }
                guard let parentWindowNumber, event.windowNumber == parentWindowNumber else { return event }
                MainActor.assumeIsolated { self?.action() }
                return nil
            }
        }

        /// The window whose clicks close the sheet, while enabled and attached.
        private func consumingWindowNumber() -> Int? {
            guard isEnabled, let parent = window?.sheetParent else { return nil }
            return parent.windowNumber
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
