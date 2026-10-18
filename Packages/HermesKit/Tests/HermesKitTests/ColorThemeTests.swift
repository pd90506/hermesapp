import Foundation
import Testing
@testable import HermesKit

struct ColorThemeTests {
    /// Desktop's themes carry their own accent, in both modes; Plain follows the system's.
    @Test func everyDesktopThemeHasAnAccent() throws {
        for theme in ColorTheme.allCases where theme != .plain {
            let accent = try #require(theme.accent, "\(theme)")
            #expect(accent.light.alpha == 1 && accent.dark.alpha == 1, "\(theme)")
        }
        #expect(ColorTheme.plain.accent == nil)
    }

    /// The default theme's accent is Nous blue, the colour of its links.
    @Test func theDefaultIsNousBlue() throws {
        let colors = MarkdownColors()
        let accent = try #require(colors.preset.accent)
        #expect(accent.light.hex == "#0053FD")
        #expect(accent.dark.hex == "#4A84FE")
        #expect(accent.light == colors.color(.link, .light))
    }

    /// The Markdown colours keep the theme; a theme saved before themes (a Markdown
    /// preset) is the same theme.
    @Test func theThemeIsTheSavedMarkdownPreset() throws {
        let json = #"{"preset":"everforest","colors":{}}"#
        let colors = try JSONDecoder().decode(MarkdownColors.self, from: Data(json.utf8))
        #expect(colors.preset == ColorTheme.everforest)
    }

    /// Restoring the Markdown colours keeps the theme.
    @Test func resettingColoursKeepsTheTheme() throws {
        var colors = MarkdownColors(preset: .catppuccin)
        colors.setColor(try #require(RGBAColor(hex: "#FF0000")), for: .heading, .light)
        colors.resetColors()
        #expect(colors.preset == .catppuccin)
        #expect(!colors.hasCustomColors)
        #expect(colors == MarkdownColors(preset: .catppuccin))
    }
}
