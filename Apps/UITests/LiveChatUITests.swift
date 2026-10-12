import XCTest

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
