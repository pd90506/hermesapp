import Foundation
import Testing
@testable import HermesKit

struct AppearanceSettingsTests {
    @Test func startsOnTheSystemLookAndPlatformSizes() {
        let settings = AppearanceSettings()
        #expect(settings.theme == .system)
        #expect(settings.size(.content, default: 13) == 13)
        #expect(settings.size(.code, default: 12) == 12)
        #expect(!settings.isCustom(.ui))
    }

    @Test func sizesAreRoundedAndClamped() {
        var settings = AppearanceSettings()
        settings.setSize(.content, 15.4, default: 13)
        #expect(settings.size(.content, default: 13) == 15)
        settings.setSize(.ui, 2, default: 13)
        #expect(settings.size(.ui, default: 13) == AppearanceSettings.sizeRange.lowerBound)
        settings.setSize(.code, 100, default: 12)
        #expect(settings.size(.code, default: 12) == AppearanceSettings.sizeRange.upperBound)
    }

    /// Back at the default, a size follows the platform again.
    @Test func settingTheDefaultForgetsTheSize() {
        var settings = AppearanceSettings()
        settings.setSize(.content, 16, default: 13)
        #expect(settings.isCustom(.content))
        settings.setSize(.content, 13, default: 13)
        #expect(!settings.isCustom(.content))
        #expect(settings.size(.content, default: 17) == 17)
    }

    @Test func resetForgetsEverything() {
        var settings = AppearanceSettings(theme: .dark)
        settings.setSize(.ui, 15, default: 13)
        settings.setSize(.code, 14, default: 12)
        settings.resetSize(.ui)
        #expect(!settings.isCustom(.ui))
        #expect(settings.isCustom(.code))
        settings.reset()
        #expect(settings == AppearanceSettings())
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = AppearanceSettings(theme: .light)
        settings.setSize(.content, 16, default: 13)
        settings.setSize(.code, 14, default: 12)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: data) == settings)
    }

    /// Saved by another version: what this one doesn't know is dropped, not fatal.
    @Test func decodingToleratesUnknownValues() throws {
        let json = #"{"theme":"sepia","sizes":{"content":15,"sidebar":11,"code":400}}"#
        let settings = try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
        #expect(settings.theme == .system)
        #expect(settings.size(.content, default: 13) == 15)
        #expect(!settings.isCustom(.code))
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: Data("{}".utf8)) == AppearanceSettings())
    }
}
