import XCTest

#if os(macOS)
/// The app's theme (Settings ▸ Appearance ▸ Theme) against a live dashboard, as
/// `LiveChatUITests` runs: picked in Settings, it colours the chat, in light and dark.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class ThemeUITests: XCTestCase {
    @MainActor
    func testAThemePickedInSettingsColoursTheChat() throws {
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

        // A chat with a reply that has Markdown in it.
        let newChat = app.buttons["New chat"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "New chat enabled")
        click(newChat)
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        click(composer)
        composer.typeText("""
            Do not use tools. Reply with only this Markdown: a level-3 heading "Themes", a line \
            with one **bold** word and a [link](https://example.com), a quote line, and a table \
            with columns Theme and Accent and two rows.
            """)
        click(app.buttons["Send"].firstMatch)
        let heading = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Themes"))
        let deadline = Date().addingTimeInterval(150)
        while heading.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        XCTAssertGreaterThanOrEqual(heading.count, 1, "the reply is shown")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attach(app, "chat, Nous (default), light")

        // Settings ▸ Appearance: Catppuccin.
        app.typeKey(",", modifierFlags: .command)
        let appearanceTab = app.toolbars.buttons["Appearance"].firstMatch
        XCTAssertTrue(appearanceTab.waitForExistence(timeout: 10), "the Settings window")
        click(appearanceTab)
        let catppuccin = app.buttons["colorTheme.catppuccin"].firstMatch
        XCTAssertTrue(catppuccin.waitForExistence(timeout: 10), "the theme swatches")
        XCTAssertTrue(app.buttons["colorTheme.nous"].firstMatch.isSelected, "Nous is the default")
        click(catppuccin)
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: catppuccin)
        XCTAssertEqual(XCTWaiter().wait(for: [picked], timeout: 5), .completed, "Catppuccin picked")
        attach(app, "settings, Catppuccin picked")

        // Dark mode, then back to the chat.
        let mode = app.descendants(matching: .any)["appearanceMode"].firstMatch
        click(mode.buttons["Dark"].firstMatch.exists ? mode.buttons["Dark"].firstMatch : mode.radioButtons["Dark"].firstMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "settings, Catppuccin, dark")
        app.typeKey("w", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach(app, "chat, Catppuccin, dark")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A coordinate click: XCUITest's `tap()` doesn't trigger SwiftUI buttons on macOS
    /// (see `LiveChatUITests.press`).
    @MainActor
    private func click(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
#endif
