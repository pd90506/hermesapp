import AppKit
import HermesKit
import SwiftUI
import Testing

/// The theme's accent (Settings ▸ Appearance ▸ Theme) as the app draws it.
@MainActor
@Suite struct ThemeColorsTests {
    private func resolved(_ color: NSColor, dark: Bool) throws -> RGBAColor {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        var result: RGBAColor?
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) {
                result = RGBAColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent,
                                   alpha: rgb.alphaComponent)
            }
        }
        return try #require(result)
    }

    /// Each theme's accent draws its light colour in light mode and its dark one in dark.
    @Test(arguments: ColorTheme.allCases.filter { $0 != .plain })
    func accentFollowsTheAppearance(theme: ColorTheme) throws {
        let accent = try #require(theme.nativeAccent)
        let pair = try #require(theme.accent)
        #expect(try resolved(accent, dark: false) == pair.light)
        #expect(try resolved(accent, dark: true) == pair.dark)
    }

    /// System leaves the tint alone, so the system's accent shows.
    @Test func systemKeepsTheSystemAccent() {
        #expect(ColorTheme.plain.nativeAccent == nil)
        #expect(ColorTheme.plain.accentColor == nil)
    }
}
