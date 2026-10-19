import XCTest

/// The chat's scroll-to-bottom button, as Desktop's: hidden at the end of the chat; shown,
/// centered just above the composer, once the chat is scrolled up, saying how many
/// messages are below; a click or tap brings the chat back down to the newest message and
/// the button goes. Screenshots in light and dark, on the Mac and on iPhone.
/// Needs replies, so the VM's Hermes needs its model key; skipped without
/// `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`. The script's sweep deletes the chat.
final class ScrollToBottomUITests: XCTestCase {
    @MainActor
    func testTheButtonScrollsBackToTheNewestMessage() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        #if os(macOS)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.appearance = .light
        }
        #if os(macOS)
        if !app.windows.firstMatch.waitForExistence(timeout: 10) { app.typeKey("n", modifierFlags: .command) }
        #else
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        #endif

        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: newChat)], timeout: 30), .completed)
        press(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the composer")

        // A long reply, then a short exchange under it: scrolled to the top, the second
        // prompt and its reply are below the screen.
        let long = "LONG-\(Int.random(in: 1000...9999))"
        let short = "SHORT-\(Int.random(in: 1000...9999))"
        send("Do not use tools. Reply with a numbered Markdown list of 50 items, each item just the word "
             + "row, and after the list a last paragraph with exactly \(long).", waitingFor: long,
             composer: composer, in: app)
        send("Reply with exactly \(short) and nothing else. Do not use tools.", waitingFor: short,
             composer: composer, in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        let button = app.buttons["scrollToBottom"].firstMatch
        XCTAssertFalse(button.exists, "no button at the end of the chat")
        attach(app, "1 at the end, light")

        for (mode, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = mode
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            scrollToTop(app)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "scrolled up, the button shows (\(name))")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertEqual(button.label, "Scroll to bottom · 2 messages",
                           "the second prompt and its reply are below the screen (\(name))")
            // Centered over the composer, just above it.
            let card = composer.frame
            XCTAssertEqual(button.frame.midX, card.midX, accuracy: 30, "centered over the composer: \(button.frame), \(card)")
            XCTAssertLessThan(button.frame.maxY, card.minY, "above the composer: \(button.frame), \(card)")
            XCTAssertGreaterThan(button.frame.maxY, card.minY - 60, "just above it: \(button.frame), \(card)")
            attach(app, "2 scrolled up, \(name)")

            press(button)
            let shortReply = app.textViews.matching(NSPredicate(format: "value == %@", short)).firstMatch
            XCTAssertTrue(eventually(timeout: 5) { !button.exists }, "back at the end, the button goes (\(name))")
            XCTAssertTrue(eventually(timeout: 5) { shortReply.exists && shortReply.isHittable },
                          "the newest reply on screen (\(name))")
            attach(app, "3 back at the end, \(name)")
        }
    }

    /// Types `prompt`, sends it and waits for the reply `marker` (a paragraph of its own,
    /// in a selectable text view; the prompt bubble holds more than the marker).
    @MainActor
    private func send(_ prompt: String, waitingFor marker: String, composer: XCUIElement, in app: XCUIApplication) {
        press(composer)
        composer.typeText(prompt)
        press(app.buttons["Send"].firstMatch)
        let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
        let deadline = Date().addingTimeInterval(180)
        while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        if reply.count < 1 { attach(app, "no reply \(marker)") }
        XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")
        // The reply settles once the turn ends.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    /// Scrolls the chat up to its first message.
    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        #if os(macOS)
        let transcript = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        for _ in 0..<6 { transcript.scroll(byDeltaX: 0, deltaY: 1500) }
        #else
        for _ in 0..<4 { app.windows.firstMatch.swipeDown(velocity: .fast) }
        #endif
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    @MainActor
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }

    /// A coordinate click on the Mac (XCUITest's `tap()` doesn't trigger SwiftUI buttons
    /// there, see `LiveChatUITests.press`), a tap on iPhone.
    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
