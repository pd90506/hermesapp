#if os(macOS)
import XCTest

/// The row under a Mac reply: a small grey Copy, a "…" menu and the time it was written.
/// The menu's Branch in New Chat opens a new chat holding the conversation up to that
/// reply (`session.branch`), listed in the session list and opened again from its row after
/// another chat. Screenshots of the row, the menu, the branch and the list.
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
        let window = app.windows.firstMatch
        let list = app.outlines.firstMatch
        let first = "ALPHA-\(Int.random(in: 1000...9999))"
        let middle = "MIDDLE-\(Int.random(in: 1000...9999))"
        let second = "BRAVO-\(Int.random(in: 1000...9999))"
        let composer = app.textViews["composer"]
        func ask(_ marker: String) {
            XCTAssertTrue(composer.waitForExistence(timeout: 30), "the composer")
            press(composer)
            composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
            press(app.buttons["Send"].firstMatch)
            let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
            let deadline = Date().addingTimeInterval(150)
            while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")
        }
        // The parent's first exchange, then another chat, then the parent's second exchange,
        // and a branch from the first reply: an older reply than the newest chats.
        press(newChat)
        ask(first)
        let parentTitle = try XCTUnwrap(chatTitle(of: window, timeout: 60), "the parent is titled")
        XCTAssertNotNil(row(titled: parentTitle, in: list, timeout: 30),
                        "the parent “\(parentTitle)” is listed: \(rowTitles(list))")
        press(newChat)
        ask(middle)
        XCTAssertNotNil(chatTitle(of: window, timeout: 60) { $0 != parentTitle }, "the other chat is titled")
        // Rows are found again before each click: a row element is bound to its place.
        press(try XCTUnwrap(row(titled: parentTitle, in: list, timeout: 30)))
        XCTAssertNotNil(chatTitle(of: window, timeout: 30) { $0 == parentTitle }, "the parent shown again")
        ask(second)
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
        let titleBefore = window.title
        branch.click()

        // The branch: the first exchange only, in a new chat.
        let deadline = Date().addingTimeInterval(30)
        while window.title == titleBefore, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertNotEqual(window.title, titleBefore, "a new chat is shown")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", first)).firstMatch
            .waitForExistence(timeout: 30), "the branch holds the first reply")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "value == %@", second)).count, 0,
                       "and not the second")
        attach(app, "3 the branch")

        // Listed, as any chat is, and opened again from its row after another chat.
        let branchTitle = try XCTUnwrap(chatTitle(of: window, timeout: 10), "the branch is titled")
        XCTAssertNotNil(row(titled: branchTitle, in: list, timeout: 15),
                        "the branch “\(branchTitle)” is listed: \(rowTitles(list))")
        attach(app, "4 the branch in the list")

        // Another chat, then back to the branch from its row.
        press(try XCTUnwrap(row(containing: middle, in: list, timeout: 5)))
        XCTAssertNotNil(chatTitle(of: window, timeout: 30) { $0 != branchTitle }, "the other chat shown")
        press(try XCTUnwrap(row(titled: branchTitle, in: list, timeout: 5)))
        XCTAssertNotNil(chatTitle(of: window, timeout: 30) { $0 == branchTitle },
                        "back on the branch from its row: \(window.title)")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", first)).firstMatch
            .waitForExistence(timeout: 30), "the branch holds the first reply again")
        attach(app, "5 back on the branch")
    }

    /// The chat's title in the window's (“Title · Profile”), once there is one that passes `test`.
    @MainActor
    private func chatTitle(of window: XCUIElement, timeout: TimeInterval,
                           _ test: (String) -> Bool = { _ in true }) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let title = window.title.components(separatedBy: " · ").dropLast().joined(separator: " · ")
            if !title.isEmpty, !["New Chat", "Side chat", "Chat", "Untitled chat"].contains(title), test(title) {
                return title
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return nil
    }

    /// The list's texts, top to bottom, for failure messages.
    @MainActor
    private func rowTitles(_ list: XCUIElement) -> String {
        list.staticTexts.allElementsBoundByIndex.map { $0.label.isEmpty ? "\($0.value ?? "")" : $0.label }
            .joined(separator: " | ")
    }

    /// The session list's row whose title contains `text`, once it is there.
    @MainActor
    private func row(containing text: String, in list: XCUIElement, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let match = NSPredicate(format: "label CONTAINS %@", text)
        repeat {
            if let row = list.outlineRows.allElementsBoundByIndex
                .first(where: { $0.staticTexts.matching(match).firstMatch.exists }) {
                return row
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return nil
    }

    /// The session list's row showing `title`, once it is there.
    @MainActor
    private func row(titled title: String, in list: XCUIElement, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let row = list.outlineRows.allElementsBoundByIndex.first(where: { $0.staticTexts[title].exists }) {
                return row
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return nil
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
