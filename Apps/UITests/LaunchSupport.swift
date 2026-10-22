import XCTest

extension XCUIApplication {
    /// Launches the app with its main window. On the Mac the system's restored state can
    /// bring it back with no main window (Settings alone, or none, after a run that closed
    /// or killed it), and every test then waited out its "connected" timeout: 11 of the 14
    /// macOS UI tests in the VM on 2026-10-21. So the saved state is ignored, and Cmd-N
    /// opens a window if none shows.
    @MainActor
    func launchWithMainWindow() {
        #if os(macOS)
        launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        launch()
        #if os(macOS)
        if !windows.firstMatch.waitForExistence(timeout: 10) { typeKey("n", modifierFlags: .command) }
        // The profile rail shown, as the tests expect: whether it is shown is kept across
        // launches, and a run that ended with it hidden left the next run's tests without it.
        let toggle = windows.firstMatch.buttons["collapseProfiles"].firstMatch
        if toggle.waitForExistence(timeout: 5), toggle.label == "Show Profiles" {
            toggle.click()
            _ = descendants(matching: .any)["profileRail"].firstMatch.waitForExistence(timeout: 5)
        }
        #endif
    }

    /// A tab of the session list's Sessions / Cron Jobs tab bar (`SessionListView`): by
    /// its identifier, or by its title where the system's tab bar doesn't carry it.
    @MainActor
    func sessionListTab(_ rawValue: String) -> XCUIElement {
        let byID = descendants(matching: .any)["sessionListTab.\(rawValue)"].firstMatch
        if byID.waitForExistence(timeout: 2) { return byID }
        let title = rawValue == "cron" ? "Cron Jobs" : "Sessions"
        let label = NSPredicate(format: "label BEGINSWITH %@", title)
        for type in [XCUIElement.ElementType.button, .radioButton, .tab] {
            let match = tabBars.descendants(matching: type).matching(label).firstMatch
            if match.exists { return match }
            let any = descendants(matching: type).matching(label).firstMatch
            if any.exists { return any }
        }
        return byID
    }
}
