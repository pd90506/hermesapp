import XCTest

/// The session list's order and unread marks (`SessionListOrder`, `SessionReadMarks`):
/// sessions are listed by when the user last wrote in them, so a reply landing in an older
/// chat doesn't lift it over the chat written in since; and a reply that came while its
/// chat wasn't on screen marks the row until the chat is opened. Compiled into
/// HermesMacUITests and HermesiOSUITests. Makes two chats; the script's sweep deletes them.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class SessionUnreadUITests: XCTestCase {
    @MainActor
    private func launchApp() throws -> XCUIApplication {
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
        return app
    }

    /// Chat A asks for a long answer; while it writes, the user leaves for a new chat B
    /// and writes there. A's answer lands after B's prompt: B stays on top, and A's row
    /// shows unread until it is opened.
    @MainActor
    func testAReplyOffScreenMarksItsRowWithoutReorderingTheList() throws {
        continueAfterFailure = false
        let app = try launchApp()
        defer { app.terminate() }

        let doneA = "DONE\(Int.random(in: 1000...9999))"
        let composerA = try openNewChat(app)
        send("Write the numbers from 1 to 300 in words, separated by commas, then finish with exactly \(doneA). Do not use tools.",
             composer: composerA, in: app)
        // Away while it answers (on iPhone, back to the list first: the chat page has no
        // New chat to wait for).
        XCTAssertTrue(waitForMessage("Write the numbers", in: app, timeout: 10), "A's prompt shown")
        XCTAssertFalse(waitForMessage(doneA, in: app, timeout: 0.5), "A still answering when left")
        showSessionList(app)

        let pongB = "PONG\(Int.random(in: 1000...9999))"
        let composerB = try openNewChat(app)
        send("Reply with exactly \(pongB) and nothing else. Do not use tools.", composer: composerB, in: app)
        XCTAssertTrue(waitForMessage(pongB, in: app, timeout: 150), "B's reply shown")
        attach(app, "1 B answered")
        showSessionList(app)

        // A's answer comes in off screen: its row is marked, under B's.
        let dot = app.descendants(matching: .any)["sessionUnreadDot"].firstMatch
        let marked = dot.waitForExistence(timeout: 240)
        attach(app, "2 A answered off screen")
        record(rowTexts(app), "rows with A unread")
        XCTAssertTrue(marked, "A's row shows unread once its answer is stored")
        let rows = sessionRows(app)
        let markedIndex = rows.firstIndex { $0.descendants(matching: .any)["sessionUnreadDot"].exists }
        XCTAssertNotNil(markedIndex, "the unread row is a session row")
        XCTAssertGreaterThan(markedIndex ?? 0, 0, "A's late answer doesn't lift it over B, written in since")
        XCTAssertEqual(rows.filter { $0.descendants(matching: .any)["sessionUnreadDot"].exists }.count, 1,
                       "only A is unread: B was on screen when it answered")

        // Opened, it is read.
        if let markedIndex { press(rows[markedIndex]) }
        XCTAssertTrue(waitForMessage(doneA, in: app, timeout: 30), "A's answer shown")
        #if os(iOS)
        showSessionList(app)
        #endif
        XCTAssertTrue(eventually(timeout: 10) { !dot.exists }, "opening A clears its mark")
        attach(app, "3 A opened")
        record(rowTexts(app), "rows after opening A")
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
        // A fresh composer, not the one of the chat left.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        return composer
    }

    @MainActor
    private func send(_ text: String, composer: XCUIElement, in app: XCUIApplication) {
        press(composer)
        composer.typeText(text)
        press(app.buttons["Send"].firstMatch)
    }

    @MainActor
    private func showSessionList(_ app: XCUIApplication) {
        #if os(iOS)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 10), "the list")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        #endif
    }

    /// The session rows, top first: not the Bot Chat, not New chat.
    @MainActor
    private func sessionRows(_ app: XCUIApplication) -> [XCUIElement] {
        #if os(macOS)
        let rows = app.outlines.firstMatch.outlineRows.allElementsBoundByIndex
        #else
        let rows = app.collectionViews.firstMatch.cells.allElementsBoundByIndex
        #endif
        return rows.filter { row in
            row.identifier != "botChatRow" && !row.descendants(matching: .any)["botChatRow"].exists
                && !row.descendants(matching: .any)["newChatRow"].exists
                && row.descendants(matching: .any)["More actions"].exists
        }
    }

    @MainActor
    private func rowTexts(_ app: XCUIApplication) -> [String] {
        sessionRows(app).prefix(6).map { row in
            let texts = row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            return row.descendants(matching: .any)["sessionUnreadDot"].exists ? "● " + texts : texts
        }
    }

    @MainActor
    private func waitForMessage(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let match = NSPredicate(format: "identifier != 'composer' AND (value CONTAINS %@ OR label CONTAINS %@)", text, text)
        let found = app.descendants(matching: .any).matching(match)
        return eventually(timeout: timeout) { found.count > 0 }
    }

    @MainActor
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func record(_ lines: [String], _ name: String) {
        let note = XCTAttachment(string: lines.joined(separator: "\n"))
        note.name = name
        note.lifetime = .keepAlways
        add(note)
        print("[SessionUnreadUITests] \(name): \(lines.joined(separator: " / "))")
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
