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

    /// The Mac's frame is the accent deepened, dark enough under white marks in every
    /// theme; Plain deepens the system's accent in the app.
    @Test func theFrameIsTheAccentDeepened() throws {
        for theme in ColorTheme.allCases where theme != .plain {
            let accent = try #require(theme.accent?.light, "\(theme)")
            let frame = try #require(theme.frame, "\(theme)")
            #expect(frame.alpha == 1, "\(theme)")
            #expect(Self.luminance(frame) < Self.luminance(accent), "\(theme)")
            #expect(Self.contrast(white: frame) >= 7, "\(theme): \(frame.hex)")
        }
        #expect(ColorTheme.plain.frame == nil)
        #expect(ColorTheme.nous.frame?.hex == "#001E5B")
    }

    /// WCAG's relative luminance.
    private static func luminance(_ color: RGBAColor) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func contrast(white color: RGBAColor) -> Double { 1.05 / (luminance(color) + 0.05) }
}
