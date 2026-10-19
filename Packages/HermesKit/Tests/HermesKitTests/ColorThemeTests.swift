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

    /// The Mac's surfaces are opaque; in each mode the chat stands apart from the chrome
    /// around it (a hairline edge helps in dark mode), and a selected row shows on the chrome.
    @Test func theSurfacesSetTheChatAndSelectionApart() throws {
        for theme in ColorTheme.allCases where theme != .plain {
            let surfaces = theme.surfaces
            let selection = try #require(surfaces.selection, "\(theme)")
            for pair in [surfaces.chrome, surfaces.chat, surfaces.composer, selection, surfaces.userBubble]
                .compactMap({ $0 }) {
                #expect(pair.light.alpha == 1 && pair.dark.alpha == 1, "\(theme)")
            }
            #expect(Self.contrast(surfaces.chrome.light, surfaces.chat.light) >= 1.15, "\(theme)")
            #expect(Self.contrast(surfaces.chrome.dark, surfaces.chat.dark) >= 1.02, "\(theme)")
            #expect(Self.contrast(selection.light, surfaces.chrome.light) >= 1.15, "\(theme): \(selection.light.hex)")
            #expect(Self.contrast(selection.dark, surfaces.chrome.dark) >= 1.3, "\(theme): \(selection.dark.hex)")
            // The profile rail's frame stands apart from the session list beside it.
            #expect(Self.contrast(surfaces.frame.light, surfaces.chrome.light) >= 1.15, "\(theme): \(surfaces.frame.light.hex)")
            #expect(Self.contrast(surfaces.frame.dark, surfaces.chrome.dark) >= 1.12, "\(theme): \(surfaces.frame.dark.hex)")
        }
    }

    /// Each theme's chrome carries its accent: no two themes share one, and the chrome
    /// leans toward the accent's hue. Plain takes the accent it is given (the system's).
    @Test func eachThemeHasItsOwnChrome() throws {
        let chromes = ColorTheme.allCases.filter { $0 != .plain }.map(\.surfaces.chrome)
        #expect(Set(chromes.map(\.light.hex)).count == chromes.count)
        #expect(Set(chromes.map(\.dark.hex)).count == chromes.count)
        let nous = ColorTheme.nous.surfaces.chrome
        #expect(nous.light.blue > nous.light.red && nous.dark.blue > nous.dark.red)
        #expect(ColorTheme.plain.surfaces.selection == nil)
        let blue = try #require(ColorTheme.nous.accent)
        #expect(ColorTheme.plain.surfaces(accent: blue).selection != nil)
    }

    /// WCAG's relative luminance.
    private static func luminance(_ color: RGBAColor) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG's contrast ratio.
    private static func contrast(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
