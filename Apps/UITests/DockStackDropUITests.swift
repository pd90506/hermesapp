import XCTest

#if os(macOS)
/// Files dragged out of a Dock stack (the Downloads fan) onto the composer become cards,
/// as from Finder. The user's report (2026-10-29): such a drop sometimes didn't take. The
/// Dock puts the drag on a pasteboard of its own, not the shared drag pasteboard the
/// composer read (`ComposerView`'s drop). And with several chats open, a hidden one's
/// composer took the drop (2026-10-30).
/// Puts its files in ~/Downloads and removes them when it ends, also when it fails.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class DockStackDropUITests: XCTestCase {
    @MainActor
    func testFilesDraggedFromTheDownloadsStackAttach() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        // A document, an XML file and a plain-text file: text comes from the Dock by its
        // type alone, like a document, and must still go as a file.
        let tag = Int.random(in: 1000...9999)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let names = ["Survey_families_\(tag).docx", "appcast-\(tag).xml", "notes-\(tag).txt"]
        for name in names {
            try "dock drop \(tag)\n".write(to: downloads.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // A teardown block, not a defer: a failed assertion ends the test without
        // unwinding it.
        addTeardownBlock {
            for name in names { try? FileManager.default.removeItem(at: downloads.appendingPathComponent(name)) }
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
        defer { app.terminate() }

        // Two chats opened in turn: the one shown first stays built, hidden, at the same
        // place (`KeptChats`). A hidden chat's text view took the drops (the user's
        // report, 2026-10-30), so each chat gets a drop while the other lies under or
        // over it.
        let rows = try twoSessionRows(app)
        for row in rows { press(row); RunLoop.current.run(until: Date().addingTimeInterval(2)) }
        let composer = app.textViews["composer"]
        let send = app.buttons["Send"].firstMatch
        // Onto the text in each chat, then onto the card's toolbar row with another app
        // in front: each a card in the composer of the chat on screen.
        let drops: [(row: XCUIElement, place: String)] = [
            (rows[0], "the text"), (rows[1], "the text"), (rows[1], "the toolbar row, another app in front"),
        ]
        for (name, (row, place)) in zip(names, drops) {
            if !row.isSelected { press(row) }
            XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
            XCTAssertTrue(send.waitForExistence(timeout: 10), "Send")
            let target = place.hasPrefix("the text")
                ? composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : send.coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 0.5))
            if place.contains("another app") { XCUIApplication(bundleIdentifier: "com.apple.finder").activate() }
            drag(name, to: target)
            let card = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "File \(name),", "File \(name),")).firstMatch
            if !card.waitForExistence(timeout: 15) {
                attach("no card for a drop on \(place)")
                // Where it went instead: the other chat, hidden under or over this one?
                press(row == rows[0] ? rows[1] : rows[0])
                RunLoop.current.run(until: Date().addingTimeInterval(3))
                attach("the other chat after a drop on \(place): the card is there: \(card.exists)")
            }
            XCTAssertTrue(card.exists, "a file dropped from the Dock stack on \(place) is a card in the chat shown")
        }
        attach("three files dropped from the Downloads stack")
    }

    /// The session list's rows, once it has at least two sessions (written in until it
    /// does, as `LiveChatUITests` does).
    @MainActor
    private func twoSessionRows(_ app: XCUIApplication) throws -> [XCUIElement] {
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let list = app.outlines.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the session list")
        let notes = ["Sessions", "Pinned", "No sessions yet", "Loading sessions…"]
        func sessionRows() -> [XCUIElement] {
            list.outlineRows.allElementsBoundByIndex.filter { row in !notes.contains { row.staticTexts[$0].exists } }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        while sessionRows().count < 2 {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
            let before = sessionRows().count
            press(newChat)
            let composer = app.textViews["composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
            press(composer)
            composer.typeText("Reply with exactly OK and nothing else. Do not use tools.")
            press(app.buttons["Send"].firstMatch)
            let deadline = Date().addingTimeInterval(90)
            while sessionRows().count <= before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            XCTAssertGreaterThan(sessionRows().count, before, "the chat written in is listed")
        }
        return Array(sessionRows().prefix(2))
    }

    /// Opens the Downloads stack and drags the item `name` out of it to `target`.
    @MainActor
    private func drag(_ name: String, to target: XCUICoordinate) {
        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let stack = dock.descendants(matching: .any)["Downloads"].firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 10), "the Downloads stack in the Dock")
        let item = dock.descendants(matching: .any)[name].firstMatch
        if !item.exists { stack.click() }
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(name) in the open stack")
        // The VM's mouse helper drags (scripts/vm-mouse.swift): XCUI's synthesized drag
        // starts no drag session from the Dock, and this runner may not post events.
        let start = CGPoint(x: item.frame.midX, y: item.frame.midY), end = target.screenPoint
        let request = "/tmp/hermesapp-uitest-mouse"
        try? "drag \(start.x) \(start.y) \(end.x) \(end.y)\n".write(toFile: request, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(20)
        while FileManager.default.fileExists(atPath: request), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request), "the VM's mouse helper dragged (scripts/vm-test.sh)")
        if item.exists { stack.click() }
    }

    /// A coordinate click: an element's `click()` may find it not hittable (rows) or miss
    /// (as `LiveChatUITests` found).
    @MainActor
    private func press(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
