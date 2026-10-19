import Foundation

/// The app's colour theme (Settings ▸ Appearance ▸ Theme): an accent, for controls, the
/// user's messages and other marks of the app, and the Markdown colours of replies
/// (`MarkdownColors`, which keeps the theme).
///
/// `[client choice]` Kept by the app, across launches. The names and accents are Hermes
/// Desktop's themes (`apps/shared/src/theme-presets.ts`, each theme's `primary`), and the
/// default is Desktop's (Nous). On the Mac a theme also paints the window's surfaces, as
/// Desktop's do (`surfaces`); iOS keeps the platform's.
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

    /// The Mac window's surfaces: the theme's Desktop palette, its chrome and selection
    /// tinted with its accent, so each theme has a colour of its own (the user,
    /// 2026-10-19: neutral surfaces made every theme look the same).
    public var surfaces: ThemeSurfaces { surfaces(accent: accent) }

    /// The surfaces tinted with `accent`: Plain passes the system's accent, which only
    /// the app knows. With no accent, the palette's neutrals and no selection or bubble.
    public func surfaces(accent: MarkdownColors.Pair?) -> ThemeSurfaces {
        var surfaces = palette
        guard let accent else { return surfaces }
        func tint(_ pair: MarkdownColors.Pair, light: Double, dark: Double) -> MarkdownColors.Pair {
            MarkdownColors.Pair(light: pair.light.mixed(with: accent.light, light),
                                dark: pair.dark.mixed(with: accent.dark, dark))
        }
        surfaces.chrome = tint(surfaces.chrome, light: Self.chromeTint.light, dark: Self.chromeTint.dark)
        surfaces.selection = tint(surfaces.chrome, light: 0.14, dark: 0.22)
        if surfaces.userBubble == nil { surfaces.userBubble = tint(surfaces.chat, light: 0.12, dark: 0.18) }
        return surfaces
    }

    /// How much of the accent the chrome takes: enough to name the theme at a glance,
    /// light enough to stay behind the chat.
    static let chromeTint = (light: 0.08, dark: 0.12)

    /// The neutrals from Desktop's palette (`theme-presets.ts`): chrome
    /// `sidebarBackground`, chat `background`, the user's messages `userBubble` (in dark
    /// its `accent`: Desktop's dark `userBubble` is darker than the chat, and reads as a
    /// hole without its border), the composer `muted` in dark.
    private var palette: ThemeSurfaces {
        func pair(_ light: String, _ dark: String) -> MarkdownColors.Pair {
            MarkdownColors.Pair(light: RGBAColor(hex: light)!, dark: RGBAColor(hex: dark)!)
        }
        return switch self {
        case .nous:
            ThemeSurfaces(chrome: pair("#F6F8FA", "#010409"), chat: pair("#FFFFFF", "#0D1117"),
                          composer: pair("#FFFFFF", "#1A1E24"), selection: nil,
                          userBubble: pair("#DAE7FD", "#17243A"))
        case .github:
            ThemeSurfaces(chrome: pair("#F6F8FA", "#010409"), chat: pair("#FFFFFF", "#0D1117"),
                          composer: pair("#FFFFFF", "#1A1E24"), selection: nil,
                          userBubble: pair("#DBE7E2", "#192A24"))
        // Latte and Mocha: mantle around base.
        case .catppuccin:
            ThemeSurfaces(chrome: pair("#E6E9EF", "#181825"), chat: pair("#EFF1F5", "#1E1E2E"),
                          composer: pair("#F7F8FA", "#29293A"), selection: nil,
                          userBubble: pair("#DCD7EE", "#38324B"))
        // Desktop's Everforest is one colour throughout: the chrome is Everforest's own `bg_dim`.
        case .everforest:
            ThemeSurfaces(chrome: pair("#EFEBD4", "#232A2E"), chat: pair("#FDF6E3", "#2D353B"),
                          composer: pair("#FEFBF1", "#343F44"), selection: nil,
                          userBubble: pair("#EDE9D2", "#434E47"))
        case .solarized:
            ThemeSurfaces(chrome: pair("#EEE8D5", "#001F26"), chat: pair("#FDF6E3", "#002B36"),
                          composer: pair("#FEFBF1", "#073642"), selection: nil,
                          userBubble: pair("#EEE8D5", "#144050"))
        // Neutral greys, tinted with the system's accent in the app.
        case .plain:
            ThemeSurfaces(chrome: pair("#F4F4F5", "#161618"), chat: pair("#FFFFFF", "#1E1E20"),
                          composer: pair("#FFFFFF", "#2A2A2D"), selection: nil, userBubble: nil)
        }
    }
}

extension RGBAColor {
    /// This colour with `amount` (0...1) of `other` mixed in, in sRGB.
    public func mixed(with other: RGBAColor, _ amount: Double) -> RGBAColor {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return RGBAColor(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue),
                         alpha: mix(alpha, other.alpha))
    }
}

/// A theme's surfaces in the Mac window, each in light and dark: the chat as a card on
/// the chrome, as Hermes Desktop lays its transcript on the sidebar's colour.
public struct ThemeSurfaces: Sendable, Hashable {
    /// The strip along the top, the profile rail and the session list.
    public var chrome: MarkdownColors.Pair
    /// The chat's card.
    public var chat: MarkdownColors.Pair
    /// The composer's field, on the chat.
    public var composer: MarkdownColors.Pair
    /// A selected row in the session list: the chrome, more of the accent in it.
    public var selection: MarkdownColors.Pair?
    /// The user's messages.
    public var userBubble: MarkdownColors.Pair?

    public init(chrome: MarkdownColors.Pair, chat: MarkdownColors.Pair, composer: MarkdownColors.Pair,
                selection: MarkdownColors.Pair?, userBubble: MarkdownColors.Pair?) {
        self.chrome = chrome
        self.chat = chat
        self.composer = composer
        self.selection = selection
        self.userBubble = userBubble
    }
}
