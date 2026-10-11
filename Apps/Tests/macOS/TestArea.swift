import AppKit

extension NSScreen {
    /// The Mac's own display (a MacBook's built-in screen), where tests may show
    /// windows; external displays are left alone. `nil` on a Mac without one.
    @MainActor
    static var builtIn: NSScreen? {
        screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        }
    }
}

extension NSRect {
    /// A test window's frame of `size`: on the built-in display when there is one,
    /// else beyond every screen. Never on an external display the user works on.
    @MainActor
    static func testArea(_ size: CGSize) -> NSRect {
        if let screen = NSScreen.builtIn {
            return NSRect(origin: screen.visibleFrame.origin, size: size)
        }
        let beyond = (NSScreen.screens.map(\.frame.minX).min() ?? 0) - size.width - 10_000
        return NSRect(origin: CGPoint(x: beyond, y: 200), size: size)
    }
}
