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
    /// system's accent.
    func colorTheme(_ theme: ColorTheme) -> some View {
        modifier(ColorThemeModifier(theme: theme))
    }
}

private struct ColorThemeModifier: ViewModifier {
    let theme: ColorTheme

    func body(content: Content) -> some View {
        content.tint(theme.accentColor)
    }
}

/// The themes as a row of swatches, each its accent with its name under it, as the
/// system's accent colours are picked (Settings ▸ Appearance).
struct ColorThemePicker: View {
    @Binding var selection: ColorTheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
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
    }

    static func label(_ theme: ColorTheme) -> String {
        switch theme {
        case .nous: "Nous"
        case .github: "GitHub"
        case .catppuccin: "Catppuccin"
        case .everforest: "Everforest"
        case .solarized: "Solarized"
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
