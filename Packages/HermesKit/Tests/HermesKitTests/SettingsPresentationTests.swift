import Testing
@testable import HermesKit

struct SettingsPresentationTests {
    @Test func launchRequiresSettingsOnlyWithoutAServer() {
        #expect(SettingsPresentation(hasServer: false).mode == .required)
        #expect(SettingsPresentation(hasServer: true).mode == .hidden)
    }

    /// Typing a URL and token into the must-connect settings can't be cut short by a click.
    @Test func requiredSettingsIgnoreOutsideClicksAndTheGear() {
        var settings = SettingsPresentation(hasServer: false)
        settings.clickedOutside()
        #expect(settings.mode == .required)
        settings.toggle()
        #expect(settings.mode == .required)
        settings.close()
        #expect(settings.mode == .hidden)
    }

    @Test func aFailedLaunchConnectRequiresSettings() {
        var settings = SettingsPresentation(hasServer: true)
        settings.requireConnection()
        #expect(settings.isRequired)
        settings.clickedOutside()
        #expect(settings.isRequired)
    }

    /// Each step from its own state: open, outside click, open, gear, open, Done.
    @Test func theGearOpensSettingsThatAnOutsideClickCloses() {
        var settings = SettingsPresentation(hasServer: true)
        settings.toggle()
        #expect(settings.isTransient)
        settings.clickedOutside()
        #expect(settings.mode == .hidden)

        settings.toggle()
        #expect(settings.isTransient)
        settings.toggle()  // the gear again: transient → hidden
        #expect(settings.mode == .hidden)

        settings.toggle()
        #expect(settings.isTransient)
        settings.close()  // Done, Esc, or connected
        #expect(settings.mode == .hidden)
    }

    /// An outside click while hidden changes nothing, so a stray one can't open anything.
    @Test func anOutsideClickWhileHiddenDoesNothing() {
        var settings = SettingsPresentation(hasServer: true)
        settings.clickedOutside()
        #expect(settings.mode == .hidden)
        #expect(!settings.isShown)
    }
}
