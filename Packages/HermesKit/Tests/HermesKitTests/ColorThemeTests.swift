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
    /// around it, and a selected row shows on the chrome.
    @Test func theSurfacesSetTheChatAndSelectionApart() throws {
        for theme in ColorTheme.allCases {
            let surfaces = theme.surfaces
            for pair in [surfaces.chrome, surfaces.chat, surfaces.composer, surfaces.selection, surfaces.userBubble]
                .compactMap({ $0 }) {
                #expect(pair.light.alpha == 1 && pair.dark.alpha == 1, "\(theme)")
            }
            for (chrome, chat) in [(surfaces.chrome.light, surfaces.chat.light), (surfaces.chrome.dark, surfaces.chat.dark)] {
                #expect(Self.contrast(chrome, chat) >= 1.04, "\(theme): \(chrome.hex) \(chat.hex)")
            }
            if let selection = surfaces.selection {
                #expect(Self.contrast(selection.light, surfaces.chrome.light) >= 1.07, "\(theme): \(selection.light.hex)")
                #expect(Self.contrast(selection.dark, surfaces.chrome.dark) >= 1.2, "\(theme): \(selection.dark.hex)")
            }
        }
        // Light chrome is darker than the chat, dark chrome darker still, as Desktop's sidebar.
        #expect(ColorTheme.nous.surfaces.chrome.light.hex == "#F6F8FA")
        #expect(ColorTheme.nous.surfaces.chat.dark.hex == "#0D1117")
        #expect(ColorTheme.plain.surfaces.selection == nil)
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
