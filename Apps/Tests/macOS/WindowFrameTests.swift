import AppKit
import SwiftUI
import Testing

// `windowFrameAutosave` in real windows: the frame is saved as the window moves and
// resizes, and set back on the next window that shows the view.

@MainActor
@Suite(.serialized) struct WindowFrameTests {
    private func window(_ name: String) -> NSWindow {
        let window = NSWindow(contentRect: .testArea(CGSize(width: 400, height: 300)),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.white.windowFrameAutosave(name))
        window.showInTestArea()
        settle()
        return window
    }

    private func settle() {
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// A frame of `size` on a screen (a saved frame off every screen isn't restored): the
    /// built-in display's corner, or the main display's in the test VM, which has no other.
    private func frame(_ size: CGSize) -> NSRect {
        let screen = NSScreen.builtIn ?? NSScreen.main
        return NSRect(origin: screen?.visibleFrame.origin ?? .zero, size: size)
    }

    @Test func savesTheFrameAndRestoresItInTheNextWindow() {
        let name = "test-\(UUID().uuidString)"
        let key = "windowFrame.\(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let first = window(name)
        let resized = frame(CGSize(width: 640, height: 420))
        first.setFrame(resized, display: true)
        settle()
        #expect(UserDefaults.standard.string(forKey: key).map(NSRectFromString) == resized)
        first.close()
        settle()

        let second = window(name)
        defer { second.close() }
        #expect(second.frame == resized)
    }

    @Test func aSecondWindowKeepsItsOwnFrame() {
        let name = "test-\(UUID().uuidString)"
        let key = "windowFrame.\(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let first = window(name)
        defer { first.close() }
        let saved = frame(CGSize(width: 640, height: 420))
        first.setFrame(saved, display: true)
        settle()

        let second = window(name)
        defer { second.close() }
        second.setFrame(frame(CGSize(width: 500, height: 350)), display: true)
        settle()
        // The second window neither took the saved frame nor overwrote it.
        #expect(UserDefaults.standard.string(forKey: key).map(NSRectFromString) == saved)
    }

    @Test func ignoresAFrameOffEveryScreen() {
        let name = "test-\(UUID().uuidString)"
        let key = "windowFrame.\(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let gone = NSRect(x: -100_000, y: -100_000, width: 640, height: 420)
        UserDefaults.standard.set(NSStringFromRect(gone), forKey: key)

        let window = window(name)
        defer { window.close() }
        #expect(window.frame != gone)
    }

    @Test func shrinksAFrameBiggerThanItsScreen() {
        let name = "test-\(UUID().uuidString)"
        let key = "windowFrame.\(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let screen = (NSScreen.builtIn ?? NSScreen.main)!.visibleFrame
        let tooBig = NSRect(origin: screen.origin, size: CGSize(width: screen.width + 500, height: screen.height + 300))
        UserDefaults.standard.set(NSStringFromRect(tooBig), forKey: key)

        let window = window(name)
        defer { window.close() }
        #expect(screen.contains(window.frame))
    }
}
