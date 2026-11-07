import XCTest

/// A process Hermes leaves running in the background (`terminal(background=true)`): the
/// background-tasks pill shows above the composer, in one row with the scroll-to-bottom
/// arrow, opens a popover with its row and Stop, which closes with a click outside, and the
/// chat's row in the sidebar carries the hollow "background task running" dot. Stop kills
/// it and the pill goes. Screenshots at each step.
/// Compiled into HermesMacUITests and HermesiOSUITests. Makes one chat; the script's
/// sweep deletes it. Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class BackgroundTasksUITests: XCTestCase {
    @MainActor
    func testABackgroundProcessShowsAndStops() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
        defer { app.terminate() }
        let composer = try openNewChat(app)

        let digits = Int.random(in: 1000...9999), marker = "STARTED\(digits)"
        send("Call the terminal tool exactly once with command \"sleep 600\" and background true. "
            + "Do nothing else, then reply with 40 lines, each just \"line\" and its number, then a last line "
            + "with the word STARTED immediately followed by the digits \(digits), and nothing else.",
            composer: composer, in: app)
        XCTAssertTrue(waitForMessage(marker, in: app, timeout: 180), "Hermes started it and replied")

        let pill = app.descendants(matching: .any).matching(identifier: "backgroundProcessesPill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "the pill shows above the composer")
        XCTAssertTrue(pill.label.contains("1 background task"), "counting it: \(pill.label)")
        #if os(macOS)
        let dot = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'sessionStatusDot' AND label == 'Background task running'")).firstMatch
        XCTAssertTrue(dot.waitForExistence(timeout: 10), "the chat's row shows work left running")
        #endif
        attach(app, "1 pill")

        // Scrolled up, the scroll-to-bottom arrow shows beside the pill, in one row.
        let jump = app.descendants(matching: .any).matching(identifier: "scrollToBottom").firstMatch
        for _ in 0..<8 where !jump.exists {
            #if os(macOS)
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4))
                .scroll(byDeltaX: 0, deltaY: 400)
            #else
            app.swipeDown()
            #endif
        }
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "scrolled up, the scroll-to-bottom pill")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "1b both pills")
        XCTAssertFalse(jump.frame.intersects(pill.frame), "apart: \(jump.frame) and \(pill.frame)")
        XCTAssertLessThan(abs(jump.frame.midY - pill.frame.midY), 2, "in one row: \(jump.frame) and \(pill.frame)")
        XCTAssertLessThan(jump.frame.maxX, pill.frame.minX, "the scroll pill first")

        press(pill)
        let row = app.descendants(matching: .any).matching(identifier: "backgroundProcessRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the card lists it")
        XCTAssertTrue(row.label.contains("sleep 600"), "by its command: \(row.label)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "2 popover")
        XCTAssertFalse(app.buttons["backgroundProcessesClose"].exists, "no close button beside Stop")

        // Outside the popover, it closes; the pill stays where it was, and opens it again.
        tapOutside(app)
        XCTAssertTrue(eventually(timeout: 5) { !row.exists }, "a click outside closes it")
        XCTAssertTrue(pill.exists, "the pill stays")
        press(pill)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the pill opens it again")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        press(pill)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(row.exists, "the pill, while open, closes it: it is outside too")
        press(pill)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "and opens it once more")
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let stop = app.buttons["backgroundProcessStop"].firstMatch
        XCTAssertTrue(stop.exists, "a running one has Stop")
        press(stop)
        XCTAssertTrue(eventually(timeout: 20) { !pill.exists && !row.exists }, "stopped, it goes")
        attach(app, "3 stopped")
    }

    // MARK: Helpers

    @MainActor
    private func openNewChat(_ app: XCUIApplication) throws -> XCUIElement {
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif
        let newChat = app.buttons["New chat"]
        let connected = newChat.waitForExistence(timeout: 30)
        if !connected { attachLaunchState(of: app, "not connected") }
        XCTAssertTrue(connected, "connected, Sessions shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        press(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        return composer
    }

    @MainActor
    private func send(_ text: String, composer: XCUIElement, in app: XCUIApplication) {
        press(composer)
        composer.typeText(text)
        press(app.buttons["Send"].firstMatch)
    }

    @MainActor
    private func waitForMessage(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let found = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier != 'composer' AND (value CONTAINS %@ OR label CONTAINS %@)", text, text))
        return eventually(timeout: timeout) { found.count > 0 }
    }

    @MainActor
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A click or tap well away from the popover, in the upper part of the chat.
    @MainActor
    private func tapOutside(_ app: XCUIApplication) {
        #if os(macOS)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.2)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        #endif
    }

    /// A coordinate click on the Mac: XCUITest's `tap()` doesn't trigger SwiftUI buttons
    /// there (see `LiveChatUITests.press`).
    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }
}
