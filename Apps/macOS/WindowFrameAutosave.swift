import AppKit
import SwiftUI

extension View {
    /// Keeps the hosting window's frame in UserDefaults under `name` and puts the window
    /// back there on the next launch.
    ///
    /// Neither SwiftUI's saved frame nor AppKit's frame autosave survives here: SwiftUI
    /// keyed its frame by the content's type name, which changes with the view code, and
    /// it clears a window's autosave name. So the frame is saved by hand, on every move or
    /// resize.
    func windowFrameAutosave(_ name: String) -> some View {
        background(WindowFrameAutosave(key: "windowFrame.\(name)"))
    }
}

private struct WindowFrameAutosave: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView { FrameKeeper(key: key) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FrameKeeper: NSView {
        let key: String
        private var observers: [any NSObjectProtocol] = []

        private struct WeakWindow {
            weak var window: NSWindow?
        }

        /// The window that owns each saved frame.
        private static var owners: [String: WeakWindow] = [:]

        init(key: String) {
            self.key = key
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // One window owns the saved frame: a second one (File ▸ New Window) opens at
            // the default size instead of on top of the first.
            if let owner = Self.owners[key]?.window, owner !== window, owner.isVisible { return }
            Self.owners[key] = WeakWindow(window: window)
            // On the next turn of the run loop: SwiftUI places a new window (its default
            // size and position) after the content is in it, which would undo the frame.
            // (A run-loop source, not the main queue, which doesn't drain while a test
            // running on it spins the run loop.)
            RunLoop.main.perform { [weak self, weak window] in
                MainActor.assumeIsolated {
                    guard let self, let window, self.window === window else { return }
                    self.restore(window)
                    self.observe(window)
                }
            }
        }

        /// The saved frame, else the one SwiftUI picked, kept on its display and no bigger
        /// than it. (A default size can be too big for a small display: the test VM's is
        /// 1024 pt wide.)
        private func restore(_ window: NSWindow) {
            var frame = window.frame
            if let saved = UserDefaults.standard.string(forKey: key).map(NSRectFromString),
                saved.width >= 100, saved.height >= 100,
                NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) })
            {
                frame = saved
            }
            guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })
                ?? window.screen ?? NSScreen.main
            else { return }
            let area = screen.visibleFrame
            frame.size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: true) }
        }

        private func observe(_ window: NSWindow) {
            let changes: [(NSNotification.Name, AnyObject)] = [
                (NSWindow.didMoveNotification, window), (NSWindow.didResizeNotification, window),
                (NSWindow.willCloseNotification, window), (NSApplication.willTerminateNotification, NSApp),
            ]
            for (name, object) in changes {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: object, queue: .main
                ) { [key, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
                    }
                })
            }
        }
    }
}
