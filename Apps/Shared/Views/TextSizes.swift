import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The three text sizes of the Appearance settings, in points, resolved against the
/// platform defaults. Views read them from the environment (`\.textSizes`), set at
/// the root of each window (`appearance(_:)`).
///
/// - UI text (`uiFont`) keeps the system text styles at the system's size (13 pt on macOS),
///   so Dynamic Type and macOS's own sizes apply; any other size scales
///   every style by the same factor.
/// - Content (messages and the composer) and code (code blocks) are the sizes the
///   Markdown renderer lays out at; on iOS they still scale with Dynamic Type.
struct TextSizes: Equatable {
    var ui: CGFloat
    var content: CGFloat
    var code: CGFloat

    /// The sizes before the user changes any. macOS: 14 pt for the UI and content and
    /// 12 pt for code (the user's choice, 2026-10). iOS: the system's body text for the UI
    /// and content, and callout (what code blocks used) for code.
    static let defaults: TextSizes = {
        #if os(macOS)
        TextSizes(ui: 14, content: 14, code: 12)
        #else
        TextSizes(ui: 17, content: 17, code: 16)
        #endif
    }()

    /// The system's body text size, which the system text styles are drawn at.
    static let systemUI: CGFloat = {
        #if os(macOS)
        13
        #else
        17
        #endif
    }()

    init(ui: CGFloat, content: CGFloat, code: CGFloat) {
        self.ui = ui
        self.content = content
        self.code = code
    }

    init(_ settings: AppearanceSettings) {
        let defaults = Self.defaults
        ui = settings.size(.ui, default: defaults.ui)
        content = settings.size(.content, default: defaults.content)
        code = settings.size(.code, default: defaults.code)
    }

    static func `default`(for kind: AppearanceSettings.TextKind) -> CGFloat {
        switch kind {
        case .ui: defaults.ui
        case .content: defaults.content
        case .code: defaults.code
        }
    }

    /// How much bigger UI text is than the system's; 1 leaves the system styles alone.
    var uiScale: CGFloat { ui / Self.systemUI }

    /// A system text style at the UI size.
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        guard uiScale != 1 else { return .system(style, design: design, weight: weight) }
        let size = (Self.pointSize(style) * uiScale).rounded()
        return .system(size: size, weight: weight ?? (style == .headline ? Self.headlineWeight : nil), design: design)
    }

    /// The UI font for text without a style of its own; nil (the system's) at the
    /// system's size.
    var uiBodyFont: Font? { uiScale == 1 ? nil : .system(size: ui) }

    #if os(macOS)
    private static let headlineWeight: Font.Weight = .bold
    #else
    private static let headlineWeight: Font.Weight = .semibold
    #endif

    /// A text style's size at the system's text size.
    static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        let native: NSFont.TextStyle
        #else
        let native: UIFont.TextStyle
        #endif
        switch style {
        case .largeTitle: native = .largeTitle
        case .title: native = .title1
        case .title2: native = .title2
        case .title3: native = .title3
        case .headline: native = .headline
        case .subheadline: native = .subheadline
        case .callout: native = .callout
        case .footnote: native = .footnote
        case .caption: native = .caption1
        case .caption2: native = .caption2
        default: native = .body
        }
        #if os(macOS)
        return NSFont.preferredFont(forTextStyle: native).pointSize
        #else
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        return UIFont.preferredFont(forTextStyle: native, compatibleWith: traits).pointSize
        #endif
    }
}

extension EnvironmentValues {
    @Entry var textSizes = TextSizes.defaults
}

extension View {
    /// A system text style at the UI text size (`TextSizes.uiFont`). Use it instead of
    /// `.font(.caption)` and the like for app chrome, so the UI size reaches it.
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(UIFontModifier(style: style, weight: weight, design: design))
    }

    /// Text the user or the model wrote, at the content size (Dynamic Type still
    /// scales it on iOS).
    func contentFont() -> some View {
        modifier(ContentFontModifier())
    }

    /// The Appearance settings for everything under it: the sizes, the UI size as
    /// the default font, and (on iOS) light or dark. On macOS the look is the whole
    /// app's (`AppearanceTheme.apply`).
    func appearance(_ settings: AppearanceSettings) -> some View {
        let sizes = TextSizes(settings)
        return environment(\.textSizes, sizes)
            .font(sizes.uiBodyFont)
            #if os(iOS)
            .preferredColorScheme(AppearanceTheme.colorScheme(settings.theme))
            #endif
    }
}

private struct UIFontModifier: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?
    @Environment(\.textSizes) private var sizes

    func body(content: Content) -> some View {
        content.font(sizes.uiFont(style, weight: weight, design: design))
    }
}

private struct ContentFontModifier: ViewModifier {
    @Environment(\.textSizes) private var sizes
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    func body(content: Content) -> some View {
        content.font(.system(size: sizes.content * typeScale))
    }
}

enum AppearanceTheme {
    static func colorScheme(_ theme: AppearanceSettings.Theme) -> ColorScheme? {
        switch theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    #if os(macOS)
    /// Light or dark for every window, sheet and menu of the app; nil follows the system.
    @MainActor
    static func apply(_ theme: AppearanceSettings.Theme) {
        switch theme {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
    #endif
}
