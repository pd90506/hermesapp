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
}
