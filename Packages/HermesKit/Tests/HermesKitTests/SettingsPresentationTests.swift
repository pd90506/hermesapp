import Testing
@testable import HermesKit

struct SettingsPresentationTests {
    @Test func launchRequiresSettingsOnlyWithoutAServer() {
        #expect(SettingsPresentation(hasServer: false).mode == .required)
        #expect(SettingsPresentation(hasServer: true).mode == .hidden)
    }

    /// The gear can't close the must-connect settings.
    @Test func requiredSettingsIgnoreTheGear() {
        var settings = SettingsPresentation(hasServer: false)
        settings.toggle()
        #expect(settings.mode == .required)
        settings.close()
        #expect(settings.mode == .hidden)
    }

    @Test func aFailedLaunchConnectRequiresSettings() {
        var settings = SettingsPresentation(hasServer: true)
        settings.requireConnection()
        #expect(settings.isRequired)
    }

    /// Each step from its own state: open, gear, open, Close.
    @Test func theGearOpensAndClosesSettings() {
        var settings = SettingsPresentation(hasServer: true)
        settings.toggle()
        #expect(settings.mode == .transient)
        settings.toggle()  // the gear again: transient → hidden
        #expect(settings.mode == .hidden)

        settings.toggle()
        #expect(settings.isShown)
        settings.close()  // Close, or connected
        #expect(settings.mode == .hidden)
    }
}
