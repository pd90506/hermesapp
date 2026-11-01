import XCTest

/// Settings ▸ Capabilities and Settings ▸ Providers against a live dashboard, in the
/// `hermesapp-test` profile. Compiled into both HermesMacUITests and HermesiOSUITests.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class ProfileSettingsUITests: XCTestCase {
    /// Each kind lists what the profile has installed; a skill's switch turns it off on
    /// the server and back on.
    @MainActor
    func testCapabilitiesListAndSwitch() throws {
        let app = try launch()
        openSettingsPage(app, tab: "Capabilities", page: "settings.capabilities")
        let skill = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'capability.skills.'")).firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 30), "the profile's skills")
        attach(app, "1 skills")

        let toggle = control(skill.identifier, in: app)
        let wasOn = isOn(toggle)
        press(toggle)
        XCTAssertTrue(eventually(timeout: 15) { self.isOn(toggle) != wasOn }, "switched")
        press(toggle)
        XCTAssertTrue(eventually(timeout: 15) { self.isOn(toggle) == wasOn }, "switched back")

        for (index, kind) in ["Toolsets", "MCP Servers", "Plugins"].enumerated() {
            press(segment(kind, in: app))
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            attach(app, "\(index + 2) \(kind.lowercased())")
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Couldn'")).firstMatch.exists,
                       "every list loads")
    }

    /// Accounts, API keys by provider and custom endpoints, read from the profile.
    @MainActor
    func testProvidersPage() throws {
        let app = try launch()
        openSettingsPage(app, tab: "Providers", page: "settings.providers")
        let accounts = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'providerAccount.'")).firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 30), "the Accounts page")
        attach(app, "1 accounts")

        press(segment("API Keys", in: app))
        let search = app.descendants(matching: .any)["providerKeys.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the API Keys page")
        let group = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'providerKeys.' AND identifier != 'providerKeys.search'"))
            .firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5), "a provider's keys")
        press(group)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, "2 api keys")

        press(segment("Endpoints", in: app))
        let add = app.descendants(matching: .any)["customEndpoint.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add Endpoint")
        attach(app, "3 endpoints")
        press(add)
        XCTAssertTrue(app.descendants(matching: .any)["endpointEditor.baseURL"].firstMatch.waitForExistence(timeout: 5),
                      "the Add Endpoint form")
        attach(app, "4 add endpoint")
    }

    // MARK: Helpers

    @MainActor
    private func launch() throws -> XCUIApplication {
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
        addTeardownBlock { app.terminate() }
        return app
    }

    @MainActor
    private func openSettingsPage(_ app: XCUIApplication, tab: String, page: String) {
        #if os(macOS)
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 60), "connected")
        app.typeKey(",", modifierFlags: .command)
        let button = app.toolbars.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the Settings window")
        press(button)
        #else
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["profilesButton"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30)
                      || app.buttons["profilesButton"].waitForExistence(timeout: 1), "connected")
        app.buttons["profilesButton"].tap()
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "the gear under the profiles")
        gear.tap()
        let row = app.buttons[page]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings lists \(tab)")
        row.tap()
        XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 5), "\(tab) opens")
        #endif
    }

    @MainActor
    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.checkBoxes[identifier].firstMatch.exists ? app.checkBoxes[identifier].firstMatch
            : app.switches[identifier].firstMatch
        #else
        app.switches[identifier].firstMatch
        #endif
    }

    @MainActor
    private func segment(_ title: String, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.radioButtons[title].firstMatch
        #else
        app.buttons[title].firstMatch
        #endif
    }

    @MainActor
    private func isOn(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber { return number.boolValue }
        return (element.value as? String) == "1"
    }

    /// A coordinate click on the Mac (XCUITest's `tap()` misses SwiftUI controls there);
    /// on iOS a switch at its right end.
    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        if element.elementType == .switch {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        } else {
            element.tap()
        }
        #endif
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }
}
