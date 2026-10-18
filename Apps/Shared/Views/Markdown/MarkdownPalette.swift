import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Markdown colours (Settings ▸ Markdown) as the renderer uses them: native colours
/// that follow light and dark for the text views, and SwiftUI colours for a colour
/// scheme. Views read it from the environment (`\.markdownPalette`), set at the root of
/// each window (`markdownColors(_:)`).
struct MarkdownPalette: Equatable, Sendable {
    var colors: MarkdownColors

    init(_ colors: MarkdownColors = MarkdownColors()) { self.colors = colors }

    /// The element's colour in `scheme`.
    func color(_ element: MarkdownColors.Element, _ scheme: ColorScheme) -> Color {
        Color(colors.color(element, scheme == .dark ? .dark : .light))
    }

    #if os(macOS)
    /// The element's colour, resolved against the drawing appearance (light or dark).
    @MainActor
    func native(_ element: MarkdownColors.Element) -> NSColor {
        Self.dynamic(colors.colors(element))
    }
    #else
    /// The element's colour, resolved against the drawing traits (light or dark).
    @MainActor
    func native(_ element: MarkdownColors.Element) -> UIColor {
        Self.dynamic(colors.colors(element))
    }
    #endif

    /// One dynamic colour per pair, so a streaming message reuses the same objects.
    #if os(macOS)
    @MainActor private static var cache: [MarkdownColors.Pair: NSColor] = [:]
    #else
    @MainActor private static var cache: [MarkdownColors.Pair: UIColor] = [:]
    #endif

    #if os(macOS)
    @MainActor
    private static func dynamic(_ pair: MarkdownColors.Pair) -> NSColor {
        if let color = cache[pair] { return color }
        let light = NSColor(pair.light), dark = NSColor(pair.dark)
        let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        if cache.count > 256 { cache.removeAll() }
        cache[pair] = color
        return color
    }
    #else
    @MainActor
    private static func dynamic(_ pair: MarkdownColors.Pair) -> UIColor {
        if let color = cache[pair] { return color }
        let light = UIColor(pair.light), dark = UIColor(pair.dark)
        let color = UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        if cache.count > 256 { cache.removeAll() }
        cache[pair] = color
        return color
    }
    #endif
}

extension Color {
    init(_ color: RGBAColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension RGBAColor {
    /// The colour a colour picker chose, in sRGB.
    @MainActor
    init(_ color: Color) {
        #if os(macOS)
        let native = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: native.redComponent, green: native.greenComponent, blue: native.blueComponent,
                  alpha: native.alphaComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}

#if os(macOS)
extension NSColor {
    convenience init(_ color: RGBAColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
#else
extension UIColor {
    convenience init(_ color: RGBAColor) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
#endif

extension EnvironmentValues {
    @Entry var markdownPalette = MarkdownPalette()
    /// Draws Markdown text views in this scheme instead of the window's: the settings
    /// preview shows light or dark whatever the app's look. Nil follows the window.
    @Entry var markdownPreviewScheme: ColorScheme? = nil
}

extension View {
    /// The Markdown colours for everything under it.
    func markdownColors(_ colors: MarkdownColors) -> some View {
        environment(\.markdownPalette, MarkdownPalette(colors))
    }
}
