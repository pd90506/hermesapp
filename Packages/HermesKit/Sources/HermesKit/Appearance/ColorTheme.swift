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

    /// The Mac window's surfaces, from the theme's Desktop palette (`theme-presets.ts`).
    public var surfaces: ThemeSurfaces {
        func pair(_ light: String, _ dark: String) -> MarkdownColors.Pair {
            MarkdownColors.Pair(light: RGBAColor(hex: light)!, dark: RGBAColor(hex: dark)!)
        }
        return switch self {
        // Desktop's slots: chrome `sidebarBackground`, chat `background`, selection
        // `accent`, the user's messages `userBubble` (in dark `accent`: Desktop's dark
        // `userBubble` is darker than the chat, and reads as a hole without its border),
        // the composer `muted` in dark.
        case .nous:
            ThemeSurfaces(chrome: pair("#F6F8FA", "#010409"), chat: pair("#FFFFFF", "#0D1117"),
                          composer: pair("#FFFFFF", "#1A1E24"), selection: pair("#E3EDFF", "#17243A"),
                          userBubble: pair("#DAE7FD", "#17243A"))
        case .github:
            ThemeSurfaces(chrome: pair("#F6F8FA", "#010409"), chat: pair("#FFFFFF", "#0D1117"),
                          composer: pair("#FFFFFF", "#1A1E24"), selection: pair("#E1ECE4", "#192A24"),
                          userBubble: pair("#DBE7E2", "#192A24"))
        // Latte and Mocha: mantle around base.
        case .catppuccin:
            ThemeSurfaces(chrome: pair("#E6E9EF", "#181825"), chat: pair("#EFF1F5", "#1E1E2E"),
                          composer: pair("#F7F8FA", "#29293A"), selection: pair("#DAD3EE", "#3D3652"),
                          userBubble: pair("#DCD7EE", "#38324B"))
        // Desktop's Everforest is one colour throughout: the chrome is Everforest's own
        // `bg_dim`, and the selection its `bg_green`, deep enough to show on it.
        case .everforest:
            ThemeSurfaces(chrome: pair("#EFEBD4", "#232A2E"), chat: pair("#FDF6E3", "#2D353B"),
                          composer: pair("#FEFBF1", "#343F44"), selection: pair("#E2E2C2", "#425047"),
                          userBubble: pair("#EDE9D2", "#434E47"))
        case .solarized:
            ThemeSurfaces(chrome: pair("#EEE8D5", "#001F26"), chat: pair("#FDF6E3", "#002B36"),
                          composer: pair("#FEFBF1", "#073642"), selection: pair("#E3DBC2", "#144050"),
                          userBubble: pair("#EEE8D5", "#144050"))
        // Neutral greys; the selection and the user's messages take the system's accent.
        case .plain:
            ThemeSurfaces(chrome: pair("#F4F4F5", "#161618"), chat: pair("#FFFFFF", "#1E1E20"),
                          composer: pair("#FFFFFF", "#2A2A2D"), selection: nil, userBubble: nil)
        }
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
    /// A selected row in the session list; nil: the accent, lightened in the app.
    public var selection: MarkdownColors.Pair?
    /// The user's messages; nil: the accent, lightened in the app.
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
