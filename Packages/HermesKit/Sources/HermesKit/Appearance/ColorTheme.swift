import Foundation

/// The app's colour theme (Settings ▸ Appearance ▸ Theme): an accent, for controls, the
/// user's messages and other marks of the app, and the Markdown colours of replies
/// (`MarkdownColors`, which keeps the theme).
///
/// `[client choice]` Kept by the app, across launches. The names and accents are Hermes
/// Desktop's themes (`apps/shared/src/theme-presets.ts`, each theme's `primary`), and the
/// default is Desktop's (Nous). Desktop's themes also paint the window's surfaces; here
/// the surfaces stay the platform's, so the app keeps its native materials.
public enum ColorTheme: String, Sendable, Hashable, Codable, CaseIterable {
    /// Hermes Desktop's default theme: GitHub's neutrals and Nous blue.
    case nous
    case github, catppuccin, everforest, solarized
    /// No colour of its own: the system's accent, and Markdown in the system's text greys
    /// and link blue, as the app looked before themes.
    case plain

    /// The accent in light and dark mode; nil follows the system's accent colour.
    public var accent: MarkdownColors.Pair? {
        func pair(_ light: String, _ dark: String) -> MarkdownColors.Pair {
            MarkdownColors.Pair(light: RGBAColor(hex: light)!, dark: RGBAColor(hex: dark)!)
        }
        return switch self {
        // `#0053FD` reads at 5.4:1 on light; dark lifts the same hue to clear AA.
        case .nous: pair("#0053FD", "#4A84FE")
        case .github: pair("#196D31", "#4F9E5E")
        case .catppuccin: pair("#6D2EBF", "#CBA6F7")
        case .everforest: pair("#586B35", "#A7C080")
        case .solarized: pair("#675E34", "#6EA1C4")
        case .plain: nil
        }
    }

    /// The Mac window's frame, as Slack's workspace colour (asked for by the user,
    /// 2026-10-18): the title bar and the profile rail, in one deep shade of the accent,
    /// the same in light and dark mode, under white marks. nil for Plain: the app deepens
    /// the system's accent the same way (`RGBAColor.deepened`).
    public var frame: RGBAColor? { accent?.light.deepened }
}

extension RGBAColor {
    /// The colour at about a third of its brightness, its hue kept: deep enough for white
    /// text and icons on it (at least 7:1, `ColorThemeTests`), as Slack's aubergine.
    public var deepened: RGBAColor {
        RGBAColor(red: red * Self.depth, green: green * Self.depth, blue: blue * Self.depth, alpha: alpha)
    }

    private static let depth = 0.36
}
