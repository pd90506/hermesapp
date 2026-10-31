import XCTest

/// Settings ▸ Notifications against a live dashboard: Hermes Desktop's switches, Replies
/// in Other Chats off by default, every kind off and disabled while Enable Notifications
/// is off. Compiled into both HermesMacUITests and HermesiOSUITests. Skipped without
/// `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class NotificationSettingsUITests: XCTestCase {
    private static let kinds = ["approval", "input", "turnDone", "turnError", "backgroundDone", "credits", "otherReply"]

    @MainActor
    func testNotificationSwitches() throws {
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

        openNotifications(app)
        let enabled = toggle("notifications.enabled", in: app)
        XCTAssertTrue(enabled.waitForExistence(timeout: 10), "Enable Notifications")
        XCTAssertTrue(isOn(enabled), "on by default")
        XCTAssertTrue(isOn(toggle("notifications.inApp", in: app)), "in-app banners on by default")
        #if os(iOS)
        attach(app, "notifications, top")
        #endif
        for kind in Self.kinds {
            let row = toggle("notifications.\(kind)", in: app)
            reveal(row, in: app)
            XCTAssertTrue(row.exists, "the \(kind) switch")
            XCTAssertEqual(isOn(row), kind != "otherReply", "\(kind) on by default, other replies off")
        }
        attach(app, "notifications, defaults")
        sendTestNotification(app)

        reveal(toggle("notifications.otherReply", in: app), in: app)
        press(toggle("notifications.otherReply", in: app))
        XCTAssertTrue(eventually { self.isOn(self.toggle("notifications.otherReply", in: app)) }, "other replies switched on")

        backToTop(app, enabled)
        press(enabled)
        XCTAssertTrue(eventually { !self.isOn(enabled) }, "notifications switched off")
        for kind in ["inApp"] + Self.kinds {
            let row = toggle("notifications.\(kind)", in: app)
            reveal(row, in: app)
            XCTAssertFalse(isOn(row), "\(kind) shows off")
            XCTAssertFalse(row.isEnabled, "\(kind) disabled")
        }
        attach(app, "notifications, all off")
        backToTop(app, enabled)
        press(enabled)
        XCTAssertTrue(eventually { self.isOn(enabled) }, "notifications back on")
        reveal(toggle("notifications.otherReply", in: app), in: app)
        XCTAssertTrue(eventually { self.isOn(self.toggle("notifications.otherReply", in: app)) },
                      "back on, other replies as they were")
    }

    /// On iOS the page's list builds rows as they scroll in: scroll until `row` is there.
    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        #if os(iOS)
        for _ in 0..<5 where !onScreen(row, in: app) { app.swipeUp() }
        #endif
    }

    @MainActor
    private func backToTop(_ app: XCUIApplication, _ top: XCUIElement) {
        #if os(iOS)
        // Only until the top row shows: one swipe more would close the settings sheet.
        for _ in 0..<5 where !onScreen(top, in: app) { app.swipeDown() }
        #endif
    }

    /// Built and inside the window, below its navigation bar. (`isHittable` throws for a
    /// row the list is still moving.)
    @MainActor
    private func onScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        return frame.minY > window.minY + 100 && frame.maxY < window.maxY - 20
    }

    /// Send Test Notification: allows notifications when the system asks, and keeps a
    /// screenshot of the whole screen with the banner. Asserts nothing about the banner,
    /// which the system draws outside the app.
    @MainActor
    private func sendTestNotification(_ app: XCUIApplication) {
        let button = app.buttons["notifications.test"].firstMatch
        reveal(button, in: app)
        XCTAssertTrue(button.exists, "Send Test Notification")
        #if os(macOS)
        press(button)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attachScreen("test notification, permission or banner")
        #else
        button.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            attachScreen("test notification, permission")
            allow.tap()
            // Asked again now that it is allowed: the first one went to the prompt.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            button.tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attachScreen("test notification, banner")
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        #endif
    }

    @MainActor
    private func attachScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func openNotifications(_ app: XCUIApplication) {
        #if os(macOS)
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 60), "connected")
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Notifications"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the Settings window")
        press(tab)
        #else
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["profilesButton"].waitForExistence(timeout: 5), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["profilesButton"].waitForExistence(timeout: 30), "the Sessions page")
        app.buttons["profilesButton"].tap()
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "the gear under the profiles")
        gear.tap()
        let page = app.buttons["settings.notifications"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "Settings lists Notifications")
        page.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5), "Notifications opens")
        #endif
    }

    @MainActor
    private func toggle(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.checkBoxes[identifier].firstMatch
        #else
        app.switches[identifier].firstMatch
        #endif
    }

    @MainActor
    private func isOn(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber { return number.boolValue }
        return (element.value as? String) == "1"
    }

    /// A coordinate click on the Mac (XCUITest's `tap()` misses SwiftUI controls there,
    /// see `LiveChatUITests.press`); on iOS the switch itself, at its right end.
    @MainActor
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
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
