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
        app.launchWithMainWindow()
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

        // Each theme in light and dark, the window as a whole: Nous dark, then
        // Catppuccin dark and light.
        app.typeKey(",", modifierFlags: .command)
        let appearanceTab = app.toolbars.buttons["Appearance"].firstMatch
        XCTAssertTrue(appearanceTab.waitForExistence(timeout: 10), "the Settings window")
        click(appearanceTab)
        let catppuccin = app.buttons["colorTheme.catppuccin"].firstMatch
        XCTAssertTrue(catppuccin.waitForExistence(timeout: 10), "the theme swatches")
        XCTAssertTrue(app.buttons["colorTheme.nous"].firstMatch.isSelected, "Nous is the default")
        pickMode("Dark", in: app)
        attach(app, "settings, Nous, dark")
        showChat(app)
        attach(app, "chat, Nous, dark")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(catppuccin.waitForExistence(timeout: 10), "the theme swatches")
        click(catppuccin)
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: catppuccin)
        XCTAssertEqual(XCTWaiter().wait(for: [picked], timeout: 5), .completed, "Catppuccin picked")
        attach(app, "settings, Catppuccin, dark")
        showChat(app)
        attach(app, "chat, Catppuccin, dark")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(catppuccin.waitForExistence(timeout: 10), "the theme swatches")
        pickMode("Light", in: app)
        showChat(app)
        attach(app, "chat, Catppuccin, light")

        // The other themes, so they can be told apart: each in light, then in dark.
        for (mode, themes) in [("Light", ["github", "everforest", "solarized", "codex", "claudeCode"]), ("Dark", ["github", "everforest", "solarized", "codex", "claudeCode"])] {
            for theme in themes {
                app.typeKey(",", modifierFlags: .command)
                let swatch = app.buttons["colorTheme.\(theme)"].firstMatch
                XCTAssertTrue(swatch.waitForExistence(timeout: 10), "the \(theme) swatch")
                click(swatch)
                pickMode(mode, in: app)
                showChat(app)
                attach(app, "chat, \(theme), \(mode.lowercased())")
            }
        }
    }

    /// Settings ▸ Appearance's light or dark mode.
    @MainActor
    private func pickMode(_ name: String, in app: XCUIApplication) {
        let mode = app.descendants(matching: .any)["appearanceMode"].firstMatch
        click(mode.buttons[name].firstMatch.exists ? mode.buttons[name].firstMatch : mode.radioButtons[name].firstMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// Closes the Settings window, back to the chat.
    @MainActor
    private func showChat(_ app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
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

#if os(iOS)
/// The theme on iPhone (Settings ▸ Appearance ▸ Theme): the swatches fit the page, two
/// rows of four, and a theme picked there colours the page's preview (the user's
/// message and a reply's Markdown) and the controls, in light and dark. Skipped without
/// `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class ThemeUITests: XCTestCase {
    @MainActor
    func testAThemePickedInSettingsColoursThePreview() throws {
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
        app.launchWithMainWindow()
        defer { app.terminate() }

        // Settings ▸ Appearance, through the profiles drawer's gear.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["profilesButton"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["profilesButton"].waitForExistence(timeout: 30), "the Sessions page")
        app.buttons["profilesButton"].tap()
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "the gear under the profiles")
        gear.tap()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), "Settings lists Appearance")
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5), "Appearance opens")

        // Every swatch on screen, inside the page's width.
        let screen = app.windows.firstMatch.frame
        for theme in ["nous", "github", "catppuccin", "everforest", "solarized", "codex", "claudeCode", "plain"] {
            let swatch = app.buttons["colorTheme.\(theme)"].firstMatch
            XCTAssertTrue(swatch.waitForExistence(timeout: 5), "the \(theme) swatch")
            XCTAssertTrue(swatch.frame.minX >= screen.minX && swatch.frame.maxX <= screen.maxX,
                          "the \(theme) swatch on screen: \(swatch.frame)")
        }

        let mode = app.descendants(matching: .any)["appearanceMode"].firstMatch
        for theme in ["codex", "claudeCode"] {
            for name in ["Light", "Dark"] {
                let swatch = app.buttons["colorTheme.\(theme)"].firstMatch
                swatch.tap()
                XCTAssertTrue(eventually { swatch.isSelected }, "\(theme) picked")
                mode.buttons[name].firstMatch.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                attach(app, "appearance, \(theme), \(name.lowercased())")
                // The preview, below the text sizes.
                let preview = app.descendants(matching: .any)["themePreview"].firstMatch
                app.swipeUp()
                XCTAssertTrue(eventually { preview.exists && preview.isHittable }, "the preview on screen")
                attach(app, "preview, \(theme), \(name.lowercased())")
                app.swipeDown()
                XCTAssertTrue(eventually { swatch.isHittable }, "back at the swatches")
            }
        }

        // Back to the defaults, for the tests after this one.
        app.buttons["colorTheme.nous"].firstMatch.tap()
        mode.buttons["System"].firstMatch.tap()
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
