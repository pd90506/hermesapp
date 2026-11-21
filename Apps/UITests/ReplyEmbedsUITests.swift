#if os(iOS)
import XCTest

/// Web images and `::preview` widgets in iOS replies (`ReplyEmbedView`): a reply holding a
/// web image shows the image, and one holding `::preview{file=…}` shows the agent's page
/// live in a web view; its `data-hermes-send` button sends a hidden prompt, whose answer
/// the agent writes into the page, which shows again after that turn. Screenshots at each
/// step. Needs a reply, so the VM's Hermes needs its model key; skipped without
/// `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`. Makes one chat; the script's sweep
/// deletes it.
final class ReplyEmbedsUITests: XCTestCase {
    static let imageURL = "https://raw.githubusercontent.com/pd90506/hermesapp/main/Apps/Desktop/electron/resources/icon.png"

    @MainActor
    func testWebImagesAndWidgetsShowInReplies() throws {
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

        // A web image on a line of its own.
        let digits = Int.random(in: 1000...9999)
        send("Do not use tools. Reply with exactly these three lines and nothing else: the word PICTURE immediately "
            + "followed by the digits \(digits), then an empty line, then ![Talaria icon](\(Self.imageURL))",
            composer: composer, in: app)
        XCTAssertTrue(waitForMessage("PICTURE\(digits)", in: app, timeout: 180), "Hermes replied")
        let image = app.buttons["Talaria icon"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 30), "the web image shows: \(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "1 web image")

        // A widget: a page the agent writes, then names with ::preview.
        let path = "/tmp/talaria-widget-\(digits).html"
        let page = "<div style=\"padding:12px;border:1px solid var(--border);border-radius:10px;background:var(--card)\">"
            + "<h3 style=\"margin:0 0 6px\">Counter</h3><p id=\"n\" style=\"color:var(--muted-foreground)\">Count: 0</p>"
            + "<button data-hermes-send=\"Increase the count in \(path) by one\" "
            + "style=\"background:var(--accent);color:white;border:0;border-radius:6px;padding:8px 14px\">Add one</button></div>"
        send("Use the write_file tool once to write this exact HTML to \(path): \(page) Then reply with exactly "
            + "two lines and nothing else: the word WIDGET immediately followed by the digits \(digits), and "
            + "::preview{file=\"\(path)\"}", composer: composer, in: app)
        XCTAssertTrue(waitForMessage("WIDGET\(digits)", in: app, timeout: 240), "Hermes wrote the page and replied")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30), "the widget's web view")
        let button = web.buttons["Add one"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the page shows in it: \(web.debugDescription)")
        XCTAssertTrue(eventually(timeout: 10) { web.staticTexts["Count: 0"].exists }, "with its count")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "2 widget")

        // Its button: a hidden prompt (no bubble; the package tests check that); after
        // that turn the page shows again.
        button.tap()
        XCTAssertTrue(eventually(timeout: 240) { web.staticTexts["Count: 1"].exists },
                      "the agent updated the page and it shows: \(web.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "3 widget after its prompt")
    }

    // MARK: Helpers

    @MainActor
    private func openNewChat(_ app: XCUIApplication) throws -> XCUIElement {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["New chat"].waitForExistence(timeout: 5), back.exists { back.tap() }
        let newChat = app.buttons["New chat"]
        let connected = newChat.waitForExistence(timeout: 30)
        if !connected { attachLaunchState(of: app, "not connected") }
        XCTAssertTrue(connected, "connected, Sessions shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        newChat.tap()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        return composer
    }

    @MainActor
    private func send(_ text: String, composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        composer.typeText(text)
        app.buttons["Send"].firstMatch.tap()
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
}
#endif
