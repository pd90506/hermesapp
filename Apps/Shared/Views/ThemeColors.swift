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
    /// system's accent. On the Mac also the theme's surfaces (`ThemeSurfaces`), for the
    /// views that paint them.
    func colorTheme(_ theme: ColorTheme) -> some View {
        modifier(ColorThemeModifier(theme: theme))
    }
}

private struct ColorThemeModifier: ViewModifier {
    let theme: ColorTheme

    func body(content: Content) -> some View {
        content
            .tint(theme.accentColor)
            #if os(macOS)
            .environment(\.surfaces, SurfaceColors(theme.macSurfaces))
            #endif
    }
}

/// A theme's surfaces as colours that follow light and dark. The defaults, before a
/// theme applies (and on iOS, which keeps the platform's surfaces), are the system's.
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

    static let system = SurfaceColors(
        frame: Color.secondary.opacity(0.12), chrome: Color.secondary.opacity(0.08), chat: Color.clear,
        composer: {
            #if os(macOS)
            Color(nsColor: .controlBackgroundColor)
            #else
            Color(uiColor: .secondarySystemBackground)
            #endif
        }(),
        selection: AnyShapeStyle(.tint.opacity(0.2)), userBubble: AnyShapeStyle(.tint.opacity(0.15)))
}

#if os(macOS)
extension ColorTheme {
    /// The Mac's surfaces; Plain's tinted with the system's accent.
    @MainActor
    var macSurfaces: ThemeSurfaces {
        guard self == .plain else { return surfaces }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let color = RGBAColor(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent)
        return surfaces(accent: MarkdownColors.Pair(light: color, dark: color))
    }
}

extension SurfaceColors {
    init(_ surfaces: ThemeSurfaces) {
        func color(_ pair: MarkdownColors.Pair) -> Color {
            Color(nsColor: dynamicColor(light: NSColor(pair.light), dark: NSColor(pair.dark)))
        }
        self.init(frame: color(surfaces.frame), chrome: color(surfaces.chrome), chat: color(surfaces.chat), composer: color(surfaces.composer),
                  selection: surfaces.selection.map { AnyShapeStyle(color($0)) } ?? Self.system.selection,
                  userBubble: surfaces.userBubble.map { AnyShapeStyle(color($0)) } ?? Self.system.userBubble)
    }
}
#endif

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

        var body: some View {
            VStack(spacing: 5) {
                Circle()
                    .fill(theme.accentColor ?? .accentColor)
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
