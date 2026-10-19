import XCTest

#if os(iOS)
/// The iPhone composer, a card floating over the chat as the Claude app's: Liquid Glass,
/// a large corner radius, `+` and the model and effort pills on the left, Send in the
/// theme's accent on the right; an attached image shows inside the card above the text.
/// The pages under it take the theme's colours, in dark a grey rather than the system's
/// black. Screenshots in light and dark, empty and with an attachment, in a few themes.
/// Empty and without the keyboard the card is one row (`+`, the field, Send). A tap on
/// the transcript, or a drag down, puts the keyboard away.
/// Uses the profile's Bot Chat, so it creates no session; it leaves the draft empty.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class ComposerUITests: XCTestCase {
    @MainActor
    func testComposerFloatsOnTheThemesPages() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/live-test.sh --ui)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launch()
        defer { app.terminate() }

        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["profilesButton"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["profilesButton"].waitForExistence(timeout: 30), "the Sessions page")
        let botChat = app.collectionViews.firstMatch.descendants(matching: .any)["botChatRow"].firstMatch
        XCTAssertTrue(botChat.waitForExistence(timeout: 30), "the Bot Chat row")

        // Claude Code in light: the chat, empty, then with a draft and an image.
        pick(theme: "claudeCode", mode: "Light", in: app)
        attach(app, "sessions, claudeCode, light")
        botChat.tap()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the Bot Chat opened")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send")
        XCTAssertFalse(app.buttons["Model"].exists, "empty and without the keyboard, the card is one row")
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(send.frame.width, 36, "Send is a full-size touch target: \(send.frame)")
        XCTAssertGreaterThan(send.frame.minX, screen.width * 0.75, "Send at the right: \(send.frame)")
        let plus = app.buttons["Attach"].firstMatch
        XCTAssertLessThan(plus.frame.maxX, screen.width * 0.25, "+ at the left: \(plus.frame)")
        XCTAssertEqual(plus.frame.midY, send.frame.midY, accuracy: 2, "+ level with Send")
        XCTAssertGreaterThan(plus.frame.minX, 16, "the card inset from the screen's edge: \(plus.frame)")
        attach(app, "chat empty, claudeCode, light")
        XCTAssertLessThan(send.frame.maxX, screen.maxX - 16, "the card inside the screen: \(send.frame)")

        composer.tap()
        XCTAssertTrue(app.buttons["Model"].firstMatch.waitForExistence(timeout: 5), "with the keyboard, the pills")
        attach(app, "chat focused, claudeCode, light")
        composer.typeText("What's in this picture?")
        // An image from the photo library (the simulator's sample photos), through `+`.
        plus.tap()
        let library = app.buttons["Photo Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5), "the + menu's Photo Library")
        XCTAssertFalse(app.buttons["Paste"].exists, "no Paste in the + menu: the text view's own pastes images")
        attach(app, "the + menu, claudeCode, light")
        // A tap while the menu still opens only closes it: let it settle first.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        library.tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        if !photo.waitForExistence(timeout: 20) {
            attach(app, "the photo picker")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "the photo picker, the elements"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(photo.exists, "a photo in the picker")
        photo.tap()
        let addButton = app.buttons["Add"].firstMatch
        if addButton.waitForExistence(timeout: 5) { addButton.tap() }
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Image '")).firstMatch
        if !card.waitForExistence(timeout: 20) { attach(app, "no image card") }
        XCTAssertTrue(card.exists, "the image's card in the composer")
        XCTAssertLessThan(card.frame.maxY, composer.frame.minY + 4, "the card above the text: \(card.frame)")
        attach(app, "chat with an image, claudeCode, light")

        // The same in dark: the draft and its image stay with the chat.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pick(theme: "claudeCode", mode: "Dark", in: app)
        attach(app, "sessions, claudeCode, dark")
        botChat.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the Bot Chat opened")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the image is still there")
        attach(app, "chat with an image, claudeCode, dark")

        // Emptied again: the image removed, the text deleted.
        // The ✕ at the tile's top trailing corner (one accessibility element with the tile).
        card.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0)).withOffset(CGVector(dx: -18, dy: 18)).tap()
        XCTAssertTrue(eventually { !card.exists }, "the image removed")
        // At the text's end, so every character is behind the caret.
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        XCTAssertTrue(eventually { !send.isEnabled }, "nothing left to send")
        attach(app, "chat empty, claudeCode, dark")

        // The keyboard goes away from the transcript: a tap on it, or a drag down.
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard is up")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(eventually { !app.keyboards.firstMatch.exists }, "a tap on the transcript puts the keyboard away")
        // Empty, with the keyboard away, the card is one row: no model pill.
        XCTAssertTrue(eventually { !app.buttons["Model"].exists }, "the card shrinks to one row")
        XCTAssertEqual(plus.frame.midY, send.frame.midY, accuracy: 2, "+ level with Send in the row")
        attach(app, "chat collapsed, claudeCode, dark")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up again")
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        top.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
        XCTAssertTrue(eventually { !app.keyboards.firstMatch.exists }, "a drag down takes the keyboard away")

        // Two more themes in dark, the system's black gone from each.
        for theme in ["codex", "nous"] {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            pick(theme: theme, mode: "Dark", in: app)
            attach(app, "sessions, \(theme), dark")
            botChat.tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 30), "the Bot Chat opened")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            attach(app, "chat empty, \(theme), dark")
        }

        // Back to the defaults, for the tests after this one.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pick(theme: "nous", mode: "System", in: app, screenshotSettings: false)
    }

    /// Turned to landscape and back, the chat fits the screen again: the transcript's
    /// column and the composer as wide as the portrait screen, not the landscape one
    /// (the user saw the chat run off the screen's right edge, 2026-10-19).
    @MainActor
    func testChatFitsTheScreenAfterRotating() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/live-test.sh --ui)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["profilesButton"].waitForExistence(timeout: 5), back.exists { back.tap() }
        let botChat = app.collectionViews.firstMatch.descendants(matching: .any)["botChatRow"].firstMatch
        XCTAssertTrue(botChat.waitForExistence(timeout: 30), "the Bot Chat row")
        botChat.tap()
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 30), "the Bot Chat opened")
        let portrait = app.windows.firstMatch.frame
        let restingX = send.frame.maxX

        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach(app, "landscape")
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach(app, "portrait again")
        XCTAssertEqual(app.windows.firstMatch.frame.width, portrait.width, accuracy: 1, "back in portrait")
        XCTAssertLessThanOrEqual(send.frame.maxX, portrait.maxX, "Send on screen: \(send.frame)")
        XCTAssertEqual(send.frame.maxX, restingX, accuracy: 1, "Send where it was before turning")
    }

    /// Settings ▸ Appearance, through the profiles drawer's gear: the theme and the mode
    /// picked, and the sheet closed, back on the Sessions page.
    @MainActor
    private func pick(theme: String, mode: String, in app: XCUIApplication, screenshotSettings: Bool = true) {
        let avatar = app.buttons["profilesButton"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10), "the Sessions page")
        avatar.tap()
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "the gear under the profiles")
        gear.tap()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), "Settings lists Appearance")
        appearance.tap()
        let swatch = app.buttons["colorTheme.\(theme)"].firstMatch
        XCTAssertTrue(swatch.waitForExistence(timeout: 5), "the \(theme) swatch")
        swatch.tap()
        XCTAssertTrue(eventually { swatch.isSelected }, "\(theme) picked")
        app.descendants(matching: .any)["appearanceMode"].firstMatch.buttons[mode].firstMatch.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if screenshotSettings, mode == "Dark" { attach(app, "settings appearance, \(theme), dark") }
        let close = app.buttons["Close"].firstMatch
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(eventually { !appearance.exists && !swatch.exists }, "Settings closed")
        // The drawer closes once the sheet has gone.
        let rail = app.descendants(matching: .any)["profileRail"].firstMatch
        if rail.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        }
        XCTAssertTrue(eventually { !rail.exists }, "the drawer closed")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
