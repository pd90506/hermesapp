import XCTest

/// Drives the real app against a live Hermes dashboard, in the `hermesapp-test`
/// profile. Compiled into both HermesMacUITests and HermesiOSUITests.
///
/// Skipped unless the runner gets `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`
/// (xcodebuild forwards `TEST_RUNNER_`-prefixed variables; `scripts/live-test.sh --ui`
/// sets them). The chats it creates are deleted by the script's sweep afterwards.
final class LiveChatUITests: XCTestCase {
    @MainActor
    private func launchApp() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/live-test.sh --ui)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
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
        newChat.tap()

        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        composer.tap()
        let marker = "PONG-\(Int.random(in: 1000...9999))"
        composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
        app.buttons["Send"].firstMatch.tap()

        // The prompt bubble also contains the marker; the reply is a second match.
        let matches = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", marker))
        let deadline = Date().addingTimeInterval(150)
        while matches.count < 2, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        XCTAssertGreaterThanOrEqual(matches.count, 2, "reply containing \(marker) shown")
    }
}
