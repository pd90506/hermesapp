import AppKit
import HermesKit
import SwiftUI
import Testing

/// The Markdown colours (Settings ▸ Markdown) as the renderer draws them, in light and dark.
@MainActor
@Suite struct MarkdownColorsRenderTests {
    private let source = """
    ## Title

    Some **bold** text, a [link](https://example.com) and `code`.

    > Quoted words.
    """

    /// `color` as drawn in light or dark, in sRGB.
    private func resolved(_ color: NSColor?, dark: Bool) throws -> RGBAColor {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        var result: RGBAColor?
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = color?.usingColorSpace(.sRGB) {
                result = RGBAColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent,
                                   alpha: rgb.alphaComponent)
            }
        }
        return try #require(result)
    }

    private func text(_ palette: MarkdownPalette, tableHeader: Bool = false,
                      source: String? = nil) -> NSAttributedString {
        MarkdownNativeText.make(MarkdownSelection(parsing: source ?? self.source), bodySize: 13,
                                palette: palette, tableHeader: tableHeader).text
    }

    private func attribute(_ key: NSAttributedString.Key, of needle: String,
                           in text: NSAttributedString) throws -> NSColor? {
        let index = (text.string as NSString).range(of: needle).location
        try #require(index != NSNotFound, "\(needle) not rendered")
        return text.attribute(key, at: index, effectiveRange: nil) as? NSColor
    }

    /// Each element takes its colour, the light one in light mode and the dark one in dark.
    @Test(arguments: [false, true]) func elementsTakeThePalettesColours(dark: Bool) throws {
        let colors = MarkdownColors(preset: .catppuccin)
        let text = text(MarkdownPalette(colors))
        let mode: MarkdownColors.Mode = dark ? .dark : .light
        let expected: [(String, NSAttributedString.Key, MarkdownColors.Element)] = [
            ("Title", .foregroundColor, .heading),
            ("bold", .foregroundColor, .bold),
            ("link", .foregroundColor, .link),
            ("code", .foregroundColor, .inlineCode),
            ("code", .backgroundColor, .inlineCodeBackground),
            ("Quoted", .foregroundColor, .quoteText),
        ]
        for (needle, key, element) in expected {
            #expect(try resolved(try attribute(key, of: needle, in: text), dark: dark) == colors.color(element, mode),
                    "\(element)")
        }
    }

    /// A colour the user changed reaches the text; plain text stays the system's label colour.
    @Test func aChangedColourReachesTheText() throws {
        var colors = MarkdownColors()
        let red = try #require(RGBAColor(hex: "#FF0000"))
        colors.setColor(red, for: .heading, .dark)
        let text = text(MarkdownPalette(colors))
        #expect(try resolved(try attribute(.foregroundColor, of: "Title", in: text), dark: true) == red)
        #expect(try resolved(try attribute(.foregroundColor, of: "Title", in: text), dark: false)
            == colors.color(.heading, .light))
        #expect(try attribute(.foregroundColor, of: "Some", in: text) == NSColor.labelColor)
    }

    @Test func tableHeaderCellsTakeTheHeaderColour() throws {
        let colors = MarkdownColors(preset: .solarized)
        let text = text(MarkdownPalette(colors), tableHeader: true, source: "**Name**")
        #expect(try resolved(try attribute(.foregroundColor, of: "Name", in: text), dark: false)
            == colors.color(.tableHeaderText, .light))
    }

    /// Reasoning keeps its grey whatever the palette.
    @Test func reasoningStaysGrey() throws {
        let built = MarkdownNativeText.make(MarkdownSelection(parsing: source), bodySize: 13, isReasoning: true,
                                            palette: MarkdownPalette(MarkdownColors(preset: .catppuccin))).text
        let index = (built.string as NSString).range(of: "Title").location
        #expect(built.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == NSColor.secondaryLabelColor)
    }

    /// A new palette re-colours a text view already showing the message.
    @Test func changingThePaletteRecolours() throws {
        let view = MarkdownSelectionTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let selection = MarkdownSelection(parsing: source)
        view.apply(selection, bodySize: 13, isReasoning: false, palette: MarkdownPalette())
        var colors = MarkdownColors()
        colors.choose(.everforest)
        view.apply(selection, bodySize: 13, isReasoning: false, palette: MarkdownPalette(colors))
        let storage = try #require(view.textStorage)
        #expect(try resolved(try attribute(.foregroundColor, of: "Title", in: storage), dark: false)
            == colors.color(.heading, .light))
        #expect(view.appliedPalette == MarkdownPalette(colors))
    }

    /// The quote's tint runs from its bar to the end of the line, over the bar's lines.
    @Test func quoteBackgroundSpansTheQuote() throws {
        let view = MarkdownSelectionTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        view.apply(MarkdownSelection(parsing: source), bodySize: 13, isReasoning: false)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        let bar = try #require(view.decorations.quoteBarRects(layoutManager: layoutManager).first)
        let background = try #require(view.decorations.quoteBackgroundRects(layoutManager: layoutManager, width: 400).first)
        #expect(background.minX == bar.minX)
        #expect(background.maxX == 400)
        #expect(background.minY == bar.minY)
        #expect(background.height == bar.height)
    }

    /// The preview draws in the look it is asked for, whatever the window's.
    @Test(arguments: [ColorScheme.light, .dark]) func previewDrawsInItsScheme(scheme: ColorScheme) throws {
        let host = NSHostingView(rootView: MarkdownView(text: source, isStreaming: false)
            .environment(\.markdownPreviewScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .aqua : .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(in: host))
        #expect(view.appearance?.name == (scheme == .dark ? .darkAqua : .aqua))
    }

    private func findTextView(in view: NSView) -> MarkdownSelectionTextView? {
        if let text = view as? MarkdownSelectionTextView { return text }
        for child in view.subviews {
            if let found = findTextView(in: child) { return found }
        }
        return nil
    }
}
