#if os(macOS)
import AppKit
import XCTest

/// The Sessions and Cron Jobs control at the bottom of the Mac session list (the system's
/// segmented control) is inset from the list's edges, and looks the same with or without
/// the pointer over the list (the system's soft edge effect drew a band only under it).
/// Screenshots of both, in light and dark.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class SessionListTabBarUITests: XCTestCase {
    @MainActor
    func testTheTabsLookTheSameWithAndWithoutThePointer() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        defer { XCUIDevice.shared.appearance = .light }
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let name = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["HERMES_UITEST_URL"] = url
            app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
            app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
            app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
            app.launchWithMainWindow()
            defer { app.terminate() }
            let sessionsTab = app.sessionListTab("sessions")
            XCTAssertTrue(sessionsTab.waitForExistence(timeout: 30), "the tabs")
            let window = app.windows.firstMatch
            let tabs = sessionsTab.frame.union(app.sessionListTab("cron").frame)
            // The bar and a few points above it, across the list's width.
            let strip = CGRect(x: tabs.minX - 8, y: tabs.minY - 12, width: tabs.width + 16, height: tabs.height + 16)

            // The pointer over the chat, away from the list.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)).hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let away = window.screenshot()
            attach(away, "tab bar, pointer away, \(name)")
            // Over the list, just above the bar.
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: tabs.midX - window.frame.minX, dy: tabs.minY - 40 - window.frame.minY)).hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let over = window.screenshot()
            attach(over, "tab bar, pointer over the list, \(name)")

            let difference = try XCTUnwrap(Self.meanDifference(away.image, over.image, in: strip, window: window.frame))
            XCTAssertLessThan(difference, 3, "the bar changes under the pointer (\(name)): mean difference \(difference)")
            // The control is set in from the list's edges, not a band across it: clear of
            // the profile rail beside the list, and inside New chat's trailing edge above.
            let rail = app.descendants(matching: .any)["profileRail"].firstMatch.frame
            let newChat = app.buttons["New chat"].firstMatch.frame
            XCTAssertGreaterThan(tabs.minX - rail.maxX, 6, "the tabs inset from the list's leading edge (\(name)): \(tabs), \(rail)")
            XCTAssertLessThan(tabs.maxX, newChat.maxX - 2, "the tabs inset from the list's trailing edge (\(name)): \(tabs), \(newChat)")
        }
    }

    @MainActor
    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// RGBA bytes of `rect` (window points) of a window screenshot.
    private static func pixels(_ image: NSImage, _ rect: CGRect, window: CGRect) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cg.width) / window.width
        let crop = CGRect(x: (rect.minX - window.minX) * scale, y: (rect.minY - window.minY) * scale,
                          width: rect.width * scale, height: rect.height * scale).integral
        guard let part = cg.cropping(to: crop) else { return nil }
        var bytes = [UInt8](repeating: 0, count: part.width * part.height * 4)
        let context = CGContext(data: &bytes, width: part.width, height: part.height, bitsPerComponent: 8,
                                bytesPerRow: part.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        return (bytes, part.width, part.height)
    }

    /// The mean per-channel difference of two screenshots within `rect`.
    private static func meanDifference(_ a: NSImage, _ b: NSImage, in rect: CGRect, window: CGRect) -> Double? {
        guard let x = pixels(a, rect, window: window), let y = pixels(b, rect, window: window),
            x.bytes.count == y.bytes.count
        else { return nil }
        var total = 0
        for i in stride(from: 0, to: x.bytes.count, by: 4) {
            for c in 0..<3 { total += abs(Int(x.bytes[i + c]) - Int(y.bytes[i + c])) }
        }
        return Double(total) / Double(x.bytes.count / 4 * 3)
    }
}
#endif
