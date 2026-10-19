#if os(macOS)
import XCTest

/// The row under a Mac reply: a small grey Copy, a "…" menu and the time it was written.
/// The menu's Branch in New Chat opens a new chat holding the conversation up to that
/// reply (`session.branch`). Screenshots of the row, the menu and the branch.
/// Needs a reply, so the VM's Hermes needs its model key; skipped without
/// `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`. The script's sweep deletes the chats.
final class MessageActionsUITests: XCTestCase {
    @MainActor
    func testTheReplysMenuBranchesIntoANewChat() throws {
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
        // A window even if the last run's app was killed without one.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 10) { app.typeKey("n", modifierFlags: .command) }
        defer { app.terminate() }

        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: newChat)], timeout: 30), .completed)
        press(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the composer")
        press(composer)
        let first = "ALPHA-\(Int.random(in: 1000...9999))"
        let second = "BRAVO-\(Int.random(in: 1000...9999))"
        for marker in [first, second] {
            composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
            press(app.buttons["Send"].firstMatch)
            let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
            let deadline = Date().addingTimeInterval(150)
            while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")
        }
        // The row is written once the turn ends; let the transcript read it back.
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        // The first reply: hovered, its row shows Copy, "…" and the time.
        let firstReply = app.textViews.matching(NSPredicate(format: "value == %@", first)).firstMatch
        firstReply.hover()
        let menus = app.descendants(matching: .any).matching(identifier: "messageMoreMenu")
        let times = app.descendants(matching: .any).matching(identifier: "messageTime")
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 10), "the reply's … menu")
        XCTAssertGreaterThanOrEqual(times.count, 2, "the times under the messages")
        attach(app, "1 the reply's row")
        // The menu under the first reply: the one closest below it.
        let below = (0..<menus.count).map { menus.element(boundBy: $0) }
            .filter { $0.frame.minY >= firstReply.frame.maxY - 2 }
            .min { $0.frame.minY < $1.frame.minY }
        let menu = try XCTUnwrap(below, "a … menu under the first reply")
        press(menu)
        let branch = app.menuItems["Branch in New Chat"].firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 5), "Branch in New Chat in the menu")
        attach(app, "2 the menu")
        let titleBefore = app.windows.firstMatch.title
        branch.click()

        // The branch: the first exchange only, in a new chat.
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(30)
        while window.title == titleBefore, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertNotEqual(window.title, titleBefore, "a new chat is shown")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", first)).firstMatch
            .waitForExistence(timeout: 30), "the branch holds the first reply")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "value == %@", second)).count, 0,
                       "and not the second")
        attach(app, "3 the branch")
    }

    @MainActor
    private func press(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
