import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension ColorTheme {
    /// The accent as one colour that follows light and dark; nil follows the system's.
    @MainActor
    var accentColor: Color? {
        #if os(macOS)
        nativeAccent.map { Color(nsColor: $0) }
        #else
        nativeAccent.map { Color(uiColor: $0) }
        #endif
    }

    #if os(macOS)
    /// The accent, resolved against the drawing appearance (light or dark).
    @MainActor
    var nativeAccent: NSColor? {
        guard let pair = accent else { return nil }
        return dynamicColor(light: NSColor(pair.light), dark: NSColor(pair.dark))
    }
    #else
    /// The accent, resolved against the drawing traits (light or dark).
    @MainActor
    var nativeAccent: UIColor? {
        guard let pair = accent else { return nil }
        return dynamicColor(light: UIColor(pair.light), dark: UIColor(pair.dark))
    }
    #endif
}

/// A colour for light and dark. Nonisolated, so its provider isn't main-actor: SwiftUI
/// resolves colours on its render thread too, where a main-actor provider trapped
/// (`dispatch_assert_queue`, the iOS app in the VM, 2026-10-18).
#if os(macOS)
nonisolated func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}
#else
nonisolated func dynamicColor(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
}
#endif

extension View {
    /// The theme's accent as the tint of everything under it: controls, the user's
    /// messages, selected rows and the app's other marks (`.tint`). Plain keeps the
    /// system's accent. Also the theme's surfaces (`ThemeSurfaces`), for the views that
    /// paint them: on iOS too, whose system black in dark the Mac never shows (the user,
    /// 2026-10-19).
    func colorTheme(_ theme: ColorTheme) -> some View {
        modifier(ColorThemeModifier(theme: theme))
    }
}

private struct ColorThemeModifier: ViewModifier {
    let theme: ColorTheme

    func body(content: Content) -> some View {
        content
            .tint(theme.accentColor)
            .environment(\.surfaces, SurfaceColors(theme.nativeSurfaces))
    }
}

/// A theme's surfaces as colours that follow light and dark. The defaults, before a
/// theme applies, are the system's.
struct SurfaceColors {
    /// The window's frame: the strip along the top and the profile rail.
    var frame: Color
    /// Under the session list and around the chat's card.
    var chrome: Color
    /// The chat's card.
    var chat: Color
    /// The composer's field.
    var composer: Color
    /// A selected sidebar row.
    var selection: AnyShapeStyle
    /// The user's messages.
    var userBubble: AnyShapeStyle
    /// On iOS, under a grouped list or form (the session list, Settings): in light the
    /// chrome, as the system's grey page; in dark the chat, not the chrome, which in
    /// several themes is nearly black.
    var page: Color
    /// On iOS, a grouped list's or form's rows, on `page`.
    var row: Color

    static let system: SurfaceColors = {
        #if os(macOS)
        let composer = Color(nsColor: .controlBackgroundColor)
        let page = Color(nsColor: .windowBackgroundColor), row = composer
        #else
        let composer = Color(uiColor: .secondarySystemBackground)
        let page = Color(uiColor: .systemGroupedBackground), row = Color(uiColor: .secondarySystemGroupedBackground)
        #endif
        return SurfaceColors(
            frame: Color.secondary.opacity(0.12), chrome: Color.secondary.opacity(0.08), chat: Color.clear,
            composer: composer, selection: AnyShapeStyle(.tint.opacity(0.2)),
            userBubble: AnyShapeStyle(.tint.opacity(0.15)), page: page, row: row)
    }()
}

extension ColorTheme {
    /// The surfaces this platform paints; Plain's tinted with the system's accent (on
    /// iOS its blue).
    @MainActor
    var nativeSurfaces: ThemeSurfaces {
        guard self == .plain else { return surfaces }
        #if os(macOS)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let color = RGBAColor(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent)
        return surfaces(accent: MarkdownColors.Pair(light: color, dark: color))
        #else
        func color(_ style: UIUserInterfaceStyle) -> RGBAColor {
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            UIColor.systemBlue.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
            return RGBAColor(red: r, green: g, blue: b)
        }
        return surfaces(accent: MarkdownColors.Pair(light: color(.light), dark: color(.dark)))
        #endif
    }
}

extension SurfaceColors {
    init(_ surfaces: ThemeSurfaces) {
        func color(_ pair: MarkdownColors.Pair) -> Color {
            #if os(macOS)
            Color(nsColor: dynamicColor(light: NSColor(pair.light), dark: NSColor(pair.dark)))
            #else
            Color(uiColor: dynamicColor(light: UIColor(pair.light), dark: UIColor(pair.dark)))
            #endif
        }
        self.init(frame: color(surfaces.frame), chrome: color(surfaces.chrome), chat: color(surfaces.chat), composer: color(surfaces.composer),
                  selection: surfaces.selection.map { AnyShapeStyle(color($0)) } ?? Self.system.selection,
                  userBubble: surfaces.userBubble.map { AnyShapeStyle(color($0)) } ?? Self.system.userBubble,
                  page: color(MarkdownColors.Pair(light: surfaces.chrome.light, dark: surfaces.chat.dark)),
                  row: color(surfaces.composer))
    }
}

extension View {
    /// On iOS, a grouped list or form on the theme's `page`, in place of the system's
    /// (black in dark). Its rows take `themedRows()`. Nothing on the Mac, where the
    /// views paint their own.
    func themedPage() -> some View {
        modifier(ThemedPage())
    }

    /// On iOS, the rows of the sections this wraps on the theme's `row` colour.
    func themedRows() -> some View {
        modifier(ThemedRows())
    }
}

/// A grouped form (Settings) on the theme's page and rows (`themedPage`, `themedRows`).
struct ThemedForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Group { content }
                .themedRows()
        }
        .formStyle(.grouped)
        .themedPage()
    }
}

private struct ThemedPage: ViewModifier {
    @Environment(\.surfaces) private var surfaces

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .scrollContentBackground(.hidden)
            .background { surfaces.page.ignoresSafeArea() }
        #else
        content
        #endif
    }
}

private struct ThemedRows: ViewModifier {
    @Environment(\.surfaces) private var surfaces

    func body(content: Content) -> some View {
        #if os(iOS)
        content.listRowBackground(surfaces.row)
        #else
        content
        #endif
    }
}

extension EnvironmentValues {
    /// The theme's surfaces (`colorTheme`).
    @Entry var surfaces = SurfaceColors.system
}

/// The themes as swatches, each its accent with its name under it, as the system's
/// accent colours are picked (Settings ▸ Appearance): one row on the Mac, two rows of
/// four on iOS, where eight don't fit across a phone.
struct ColorThemePicker: View {
    @Binding var selection: ColorTheme

    var body: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 14) { swatches }
        #else
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4),
                  spacing: 12) { swatches }
        #endif
    }

    private var swatches: some View {
        ForEach(ColorTheme.allCases, id: \.self) { theme in
            Button {
                selection = theme
            } label: {
                Swatch(theme: theme, isSelected: theme == selection)
            }
            .buttonStyle(.plain)
            .help(Self.label(theme))
            .accessibilityLabel(Self.label(theme))
            .accessibilityAddTraits(theme == selection ? .isSelected : [])
            .accessibilityIdentifier("colorTheme.\(theme.rawValue)")
        }
    }

    static func label(_ theme: ColorTheme) -> String {
        switch theme {
        case .nous: "Nous"
        case .github: "GitHub"
        case .catppuccin: "Catppuccin"
        case .everforest: "Everforest"
        case .solarized: "Solarized"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .plain: "System"
        }
    }

    private struct Swatch: View {
        let theme: ColorTheme
        let isSelected: Bool

        private static let size: CGFloat = 26

        /// The system's accent for System: `.accentColor` is the tint, the theme picked.
        private static var systemAccent: Color {
            #if os(macOS)
            Color(nsColor: .controlAccentColor)
            #else
            Color(uiColor: .systemBlue)
            #endif
        }

        var body: some View {
            VStack(spacing: 5) {
                Circle()
                    .fill(theme.accentColor ?? Self.systemAccent)
                    .overlay { Circle().strokeBorder(.black.opacity(0.12)) }
                    .frame(width: Self.size, height: Self.size)
                    .padding(3)
                    // A form's label lines up with the swatch, not the name under it.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear),
                                          lineWidth: 2)
                    }
                Text(ColorThemePicker.label(theme))
                    .uiFont(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
    }
}
