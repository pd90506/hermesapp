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
        let settings = SessionSourceSettings(newSessionSource: "desktop", hiddenSources: ["cron", "telegram"])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(SessionSourceSettings.self, from: data) == settings)
    }

    @Test func labelsKnownSourcesAndKeepsUnknownOnes() {
        #expect(SessionSourceSettings.label(for: "telegram") == "Telegram")
        #expect(SessionSourceSettings.label(for: "TUI") == "Terminal (TUI)")
        #expect(SessionSourceSettings.label(for: "irc") == "irc")
    }
}
