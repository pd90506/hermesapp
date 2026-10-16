import XCTest
#if os(macOS)
import AppKit
#endif

/// Drives the real app against a live Hermes dashboard, in the `hermesapp-test`
/// profile. Compiled into both HermesMacUITests and HermesiOSUITests.
///
/// Skipped unless the runner gets `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`
/// (xcodebuild forwards `TEST_RUNNER_`-prefixed variables; `scripts/live-test.sh --ui`
/// sets them). The chats it creates are deleted by the script's sweep afterwards.
final class LiveChatUITests: XCTestCase {
    @MainActor
    private func launchApp(servers: Int = 1) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/live-test.sh --ui)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = String(servers)
        app.launch()
        return app
    }

    @MainActor
    func testNewChatSendsAndShowsTheReply() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        #if os(iOS)
        // iPhone may start on the chat; the sidebar is one Back away.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)

        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        let marker = "PONG-\(Int.random(in: 1000...9999))"
        composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
        press(app.buttons["Send"].firstMatch)

        // The reply is exactly the marker, in a selectable text view (its value); the
        // prompt bubble holds more than the marker.
        let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
        let deadline = Date().addingTimeInterval(150)
        while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        if reply.count < 1 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "no reply"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")
    }

    /// A turn that runs tools and answers with a table: once the reply is in, its tool
    /// calls are one closed summary line ("Ran 2 commands"), which opens to the calls.
    @MainActor
    func testToolCallsFoldIntoOneSummary() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)

        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        composer.typeText("Use the terminal tool twice: first run `echo alpha`, then run `echo beta`. "
            + "Then reply with only a Markdown table with the columns Command and Output, one row per command.")
        press(app.buttons["Send"].firstMatch)

        let summary = app.buttons.matching(identifier: "toolRunSummary").firstMatch
        let settled = NSPredicate(format: "label MATCHES 'Ran [2-9] commands.*'")
        let deadline = Date().addingTimeInterval(180)
        while !(summary.exists && settled.evaluate(with: summary)), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        attach(app, "settled")
        XCTAssertTrue(summary.exists && settled.evaluate(with: summary),
                      "one summary line for the turn's tool calls, got \(summary.exists ? summary.label : "none")")
        XCTAssertEqual(app.buttons.matching(identifier: "toolCallRow").count, 0, "the calls are folded")

        // The live run's line becomes the turn's line as the reply lands: let it
        // settle before clicking it.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        press(summary)
        let rows = app.buttons.matching(identifier: "toolCallRow")
        let opened = Date().addingTimeInterval(10)
        while rows.count < 2, Date() < opened { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        attach(app, "opened")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "opening the summary shows each call")
    }

    #if os(macOS)
    /// The pointer over the title bar, or over the top of the chat, leaves the chat
    /// column alone. macOS 26 showed the window toolbar's background there: a band
    /// from the top of the window down to the first message, with a line under it
    /// (gray in dark mode; in the VM's light mode only the line shows).
    @MainActor
    func testHoveringTheTitleBarDoesNotShadeTheChat() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")

        // A new chat is one short line at the bottom: the top of the chat column is
        // empty. Compared: a column of pixels from just under the title bar to the
        // composer, away from where the pointer goes.
        let window = app.windows.firstMatch
        let frame = window.frame
        let x = composer.frame.midX - frame.minX
        let column = (x: x + 120, from: CGFloat(56), to: composer.frame.minY - frame.minY - 16)
        func hover(_ y: CGFloat) {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - 120, dy: y)).hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        func pixels(_ name: String) -> [[UInt8]] {
            let shot = window.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return Self.pixels(of: shot.image, column: column, in: frame.size)
        }

        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let away = pixels("pointer on the composer")
        XCTAssertFalse(away.isEmpty, "read the chat column")
        hover(16)
        let titleBar = pixels("pointer on the title bar")
        hover(220)
        let top = pixels("pointer on the top of the chat")
        XCTAssertNil(Self.firstDifference(away, titleBar), "the title bar under the pointer shades the chat")
        XCTAssertNil(Self.firstDifference(away, top), "the top of the chat under the pointer shades it")
    }

    /// The session list's header (title bar, New chat) keeps one look: the same glass
    /// whether or not the pointer is over the title bar. macOS 26 showed the toolbar's
    /// glass only on hover (or with rows scrolled under it), so the header changed as
    /// the pointer crossed it.
    @MainActor
    func testSessionListHeaderLooksTheSameUnderThePointer() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")

        // From the top of the window to a little under the title bar, just left of New
        // chat (at the column's trailing edge), away from where the pointer goes.
        let window = app.windows.firstMatch
        let frame = window.frame
        let row = newChat.frame
        let column = (x: row.minX - 12 - frame.minX, from: CGFloat(4), to: row.maxY + 24 - frame.minY)
        func shot(_ name: String) -> [[UInt8]] {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let shot = window.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return Self.pixels(of: shot.image, column: column, in: frame.size)
        }

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).hover()
        let away = shot("pointer on the chat column")
        XCTAssertFalse(away.isEmpty, "read the session list's header")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.minX - 60 - frame.minX, dy: 16)).hover()
        let titleBar = shot("pointer on the session list's title bar")
        XCTAssertNil(Self.firstDifference(away, titleBar), "the header changes under the pointer")
    }

    /// The RGB of each pixel down a column of the screenshot, in window points
    /// (top-left origin).
    private static func pixels(of image: NSImage, column: (x: CGFloat, from: CGFloat, to: CGFloat),
                               in size: CGSize) -> [[UInt8]] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        // The bitmap's first row is the image's top row.
        let scale = CGFloat(width) / size.width
        let px = min(width - 1, Int(column.x * scale))
        return (Int(column.from * scale)..<min(height, Int(column.to * scale))).map { row in
            let i = (row * width + px) * 4
            return [bytes[i], bytes[i + 1], bytes[i + 2]]
        }
    }

    /// Where two columns first differ by more than rounding, as "row: before -> after".
    private static func firstDifference(_ a: [[UInt8]], _ b: [[UInt8]]) -> String? {
        guard a.count == b.count else { return "\(a.count) rows vs \(b.count)" }
        for (row, (p, q)) in zip(a, b).enumerated() where zip(p, q).contains(where: { abs(Int($0) - Int($1)) > 2 }) {
            return "row \(row): \(p) -> \(q)"
        }
        return nil
    }
    #endif

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Two servers (the same dashboard twice): both connect, each on its own socket,
    /// and the sidebar names the server it lists.
    @MainActor
    func testTwoServersConnectAndAreNamed() throws {
        continueAfterFailure = false
        let app = try launchApp(servers: 2)
        defer { app.terminate() }
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        if !waitForText(in: app, "All 2 servers connected", timeout: 60) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "not both connected"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("both servers connected")
        }
        XCTAssertTrue(waitForText(in: app, "Test 1", timeout: 10), "the Sessions list is headed by its server")
        let newChat = app.buttons["New chat"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
    }

    /// Whether some text containing `text` shows up: a static text (macOS keeps its
    /// string in the value, iOS in the label) or a combined element's label.
    @MainActor
    private func waitForText(in app: XCUIApplication, _ text: String, timeout: TimeInterval) -> Bool {
        let texts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
        let others = app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", text))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if texts.count > 0 || others.count > 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while Date() < deadline
        return false
    }

    /// A click in the element's middle. On macOS, XCUITest's `tap()` (on the element or a
    /// coordinate) did not trigger SwiftUI buttons such as New chat, nor find a hit point
    /// in the composer; a coordinate `click()` did (checked in a VM, 2026-10).
    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }
}
