import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

struct SessionSourceSettingsTests {
    @Test func hidesOnlyTheChosenSourcesIgnoringCase() {
        var settings = SessionSourceSettings()
        settings.setHidden(true, "Cron")

        #expect(!settings.shows(SessionSummary(id: "a", source: "cron")))
        #expect(!settings.shows(SessionSummary(id: "b", source: " CRON ")))
        #expect(settings.shows(SessionSummary(id: "c", source: "telegram")))
        #expect(settings.shows(SessionSummary(id: "d")))
        #expect(settings.isHidden("cron"))

        settings.setHidden(false, "cron")
        #expect(settings.shows(SessionSummary(id: "a", source: "cron")))
    }

    @Test func survivesEncoding() throws {
        let settings = SessionSourceSettings(hiddenSources: ["cron", "telegram"])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(SessionSourceSettings.self, from: data) == settings)
    }

    /// Older versions stored a chosen source for new sessions; it no longer applies.
    @Test func decodesSettingsWithTheOldNewSessionSource() throws {
        let data = Data(#"{"newSessionSource":"tui","hiddenSources":["cron"]}"#.utf8)
        #expect(try JSONDecoder().decode(SessionSourceSettings.self, from: data) == SessionSourceSettings(hiddenSources: ["cron"]))
    }

    @Test func labelsKnownSourcesAndKeepsUnknownOnes() {
        #expect(SessionSourceSettings.label(for: "telegram") == "Telegram")
        #expect(SessionSourceSettings.label(for: "TUI") == "Terminal (TUI)")
        #expect(SessionSourceSettings.label(for: "irc") == "irc")
    }
}
