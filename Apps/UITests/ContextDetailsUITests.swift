import XCTest

/// The context gauge's details after a real reply: the total, the `~` estimates under it
/// and, when the estimates fall short of the total, how much they leave out.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class ContextDetailsUITests: XCTestCase {
    @MainActor
    func testDetailsMarkTheEstimates() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/live-test.sh --ui)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
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

        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        press(composer)
        let marker = "PONG-\(Int.random(in: 1000...9999))"
        composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
        press(app.buttons["Send"].firstMatch)
        let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
        let deadline = Date().addingTimeInterval(150)
        while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")

        // The breakdown is read once the turn has ended.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let gauge = app.buttons["contextGauge"].firstMatch
        XCTAssertTrue(gauge.waitForExistence(timeout: 30), "the context gauge")
        press(gauge)
        XCTAssertTrue(app.staticTexts["This Session"].firstMatch.waitForExistence(timeout: 10), "the details")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attach(app, "context details")
        let marked = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "~", "~")
        XCTAssertTrue(app.staticTexts.matching(marked).firstMatch.exists, "the estimates are marked")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }
}
