import XCTest

/// The clarify card with a real question from Hermes: two questions in one call, the
/// choices laid out as rows to tap (not folded into a menu), picking a single-select
/// choice moves on to the next question, a multi-select one toggles, and Send Answers
/// gets the answers to Hermes. Screenshots at each step.
/// Compiled into HermesMacUITests and HermesiOSUITests. Makes one chat; the script's
/// sweep deletes it. Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class ClarifyCardUITests: XCTestCase {
    @MainActor
    func testChoicesShowAsRowsAndTheAnswersReachHermes() throws {
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

        let marker = "ANSWERED\(Int.random(in: 1000...9999))"
        send("Call the clarify tool exactly once, with two questions in that one call. Question 1: "
            + "\"Which colour should the banner be?\" with choices Red, Green, Blue. Question 2: "
            + "\"Which sizes should we print?\" with choices Small, Medium, Large and multi_select true. "
            + "After I answer, reply with \(marker) followed by my answers, and nothing else.",
            composer: composer, in: app)

        let choices = app.descendants(matching: .any).matching(identifier: "clarifyChoice")
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 180), "the card's choices shown as rows")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "1 first question")
        XCTAssertTrue(choice("Green", in: app).exists, "every choice is a row, no menu to open")
        XCTAssertTrue(choice("Blue", in: app).exists)

        press(choice("Green", in: app))
        XCTAssertTrue(choice("Medium", in: app).waitForExistence(timeout: 5), "on to the second question")
        attach(app, "2 second question")

        press(choice("Small", in: app))
        press(choice("Large", in: app))
        XCTAssertTrue(choice("Large", in: app).isSelected, "a multi-select choice is ticked")
        XCTAssertTrue(choice("Medium", in: app).exists, "and the question stays in view")
        attach(app, "3 two sizes picked")

        let sendAnswers = app.buttons["clarifySend"].firstMatch
        XCTAssertTrue(sendAnswers.isEnabled, "Send Answers enabled")
        press(sendAnswers)
        XCTAssertTrue(eventually(timeout: 10) { !choices.firstMatch.exists }, "the card goes once answered")
        XCTAssertTrue(waitForMessage(marker, in: app, timeout: 150), "Hermes replies with the answers")
        attach(app, "4 answered")
        let reply = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier != 'composer' AND (value CONTAINS %@ OR label CONTAINS %@)", marker, marker)).firstMatch
        let text = [reply.label, reply.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(text.contains("Green"), "the reply names the colour: \(text)")
        XCTAssertTrue(text.contains("Small") && text.contains("Large"), "and both sizes: \(text)")
    }

    // MARK: Helpers

    @MainActor
    private func choice(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "clarifyChoice")
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

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
