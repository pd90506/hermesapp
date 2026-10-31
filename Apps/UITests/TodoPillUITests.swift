import XCTest

/// The task list pill with a real Todo list from Hermes: the pill shows above the
/// composer with the progress, opens into the list, follows the agent's updates,
/// and goes once the list is finished and the next prompt is sent. Screenshots at each step.
/// Compiled into HermesMacUITests and HermesiOSUITests. Makes one chat; the script's
/// sweep deletes it. Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class TodoPillUITests: XCTestCase {
    @MainActor
    func testThePillFollowsTheListAndGoesAfterItIsDone() throws {
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

        // The marker never appears whole in the prompt, so only the reply matches it.
        let firstDigits = Int.random(in: 1000...9999), first = "PLANNED\(firstDigits)"
        send("Call the todo_list tool exactly once, writing this list of five tasks: "
            + "id 1 \"Read the brief\" completed, id 2 \"Sketch the layout\" completed, "
            + "id 3 \"Build the pill and the panel\" in_progress, id 4 \"Run the tests\" pending, "
            + "id 5 \"Take screenshots\" pending. Do nothing else, then reply with 40 lines, each just "
            + "\"line\" and its number, then a last line with the word PLANNED immediately followed by the digits \(firstDigits), and nothing else.",
            composer: composer, in: app)
        XCTAssertTrue(waitForMessage(first, in: app, timeout: 180), "Hermes wrote the list and replied")

        let pill = app.descendants(matching: .any).matching(identifier: "todoPill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the pill shows above the composer")
        XCTAssertTrue(pill.label.contains("2 of 5"), "with the progress: \(pill.label)")
        attach(app, "1 pill in progress")

        // Scrolled up, the scroll-to-bottom pill shows above the task pill, apart from it.
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
        XCTAssertLessThan(jump.frame.maxY, pill.frame.minY, "the scroll pill above the task pill")
        press(jump)
        XCTAssertTrue(eventually(timeout: 5) { !jump.exists }, "back at the end")

        press(pill)
        let panel = app.descendants(matching: .any).matching(identifier: "todoPanel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the pill opens the list")
        XCTAssertTrue(waitForMessage("Build the pill and the panel", in: app, timeout: 5), "each task listed")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "2 list in progress")
        press(app.buttons["todoClose"].firstMatch)
        XCTAssertTrue(eventually(timeout: 5) { !panel.exists }, "Close puts the list away")

        let secondDigits = Int.random(in: 1000...9999), second = "FINISHED\(secondDigits)"
        send("Call the todo_list tool exactly once with merge true, marking ids 3, 4 and 5 completed. "
            + "Do nothing else, then reply with the word FINISHED immediately followed by the digits \(secondDigits), and nothing else.", composer: composer, in: app)
        XCTAssertTrue(waitForMessage(second, in: app, timeout: 180), "Hermes finished the list and replied")
        XCTAssertTrue(eventually(timeout: 10) { pill.exists && pill.label.contains("All tasks complete") },
                      "a finished list stays after its turn: \(pill.label)")
        attach(app, "3 pill finished")
        press(pill)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the finished list opens")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "4 list finished")
        press(app.buttons["todoClose"].firstMatch)
        XCTAssertTrue(eventually(timeout: 5) { !panel.exists })

        send("Reply with OK and nothing else.", composer: composer, in: app)
        XCTAssertTrue(eventually(timeout: 10) { !pill.exists }, "the next prompt takes the finished list away")
        attach(app, "5 next prompt")
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
