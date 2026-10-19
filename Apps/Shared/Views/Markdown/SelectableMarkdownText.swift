import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
private typealias NativeFont = NSFont
private typealias NativeColor = NSColor
#else
import UIKit
private typealias NativeFont = UIFont
private typealias NativeColor = UIColor
#endif

private extension NativeColor {
    static var mdLabel: NativeColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }
    static var mdSecondary: NativeColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }
}

/// Spacing and indents, matching the former one-view-per-block layout.
enum MarkdownLayout {
    static let blockGap: CGFloat = 10
    static let listItemGap: CGFloat = 6
    static let quoteIndent: CGFloat = 12
    static let quoteBarWidth: CGFloat = 3
    static let markerGap: CGFloat = 6
    static let codePadding: CGFloat = 10
    /// Space above the language line, and between it and the code.
    static let codeHeaderTop: CGFloat = 6
    static let codeHeaderBottom: CGFloat = 4
    #if os(macOS)
    static let copyButtonSize = CGSize(width: 24, height: 20)
    #else
    static let copyButtonSize = CGSize(width: 36, height: 28)
    #endif

    static func width(of indent: MarkdownSelection.Run.Indent) -> CGFloat {
        switch indent {
        case .quote: quoteIndent
        case .list(let ordered): markerColumn(ordered: ordered) + markerGap
        }
    }

    static func width(of indents: some Sequence<MarkdownSelection.Run.Indent>) -> CGFloat {
        indents.reduce(0) { $0 + width(of: $1) }
    }

    static func markerColumn(ordered: Bool) -> CGFloat { ordered ? 20 : 12 }
}

/// Builds one attributed string for a selectable prose run. Paragraphs, lists,
/// headings, quotes and math share one native selection host.
@MainActor
enum MarkdownNativeText {
    struct Built {
        let text: NSAttributedString
        /// Where each run starts, relative to `text`.
        let runStarts: [Int]
    }

    /// The image for a math run, or nil to show its source. A formula still
    /// streaming in always shows its source, so it does not flip between image
    /// and text as each delta makes the partial LaTeX valid or invalid.
    static func renderedMath(_ math: MathSnippet, fontSize: CGFloat) -> MathRenderer.Rendered? {
        guard math.isClosed else { return nil }
        return MathRenderer.render(math.latex, fontSize: fontSize, display: math.isDisplay)
    }

    /// Renders `selection.runs[start...]`.
    /// `codeSize` is the code block size; nil keeps it at callout's ratio to body.
    /// `tableHeader` colours the text as a table's header row.
    static func make(_ selection: MarkdownSelection, from start: Int = 0, bodySize: CGFloat,
                     codeSize: CGFloat? = nil, isReasoning: Bool = false,
                     palette: MarkdownPalette = MarkdownPalette(), tableHeader: Bool = false) -> Built {
        let code = codeSize ?? Self.codeSize(bodySize)
        let runs = selection.runs
        let result = NSMutableAttributedString()
        var starts: [Int] = []
        guard start < runs.count else { return Built(text: result, runStarts: starts) }
        // A paragraph takes the style of its first run, so its lines share one indent.
        var paragraphStart = start
        while paragraphStart > 0, !runs[paragraphStart - 1].text.hasSuffix("\n") { paragraphStart -= 1 }
        var paragraph = paragraphStyle(at: paragraphStart, in: runs, bodySize: bodySize)
        var previousFont = font(for: runs[start > 0 ? start - 1 : start], bodySize: bodySize, codeSize: code)
        for index in start..<runs.count {
            let run = runs[index]
            if index > start, runs[index - 1].text.hasSuffix("\n") {
                paragraph = paragraphStyle(at: index, in: runs, bodySize: bodySize)
            }
            starts.append(result.length)
            // A separator ends the previous paragraph, so it takes that line's font.
            let font = run.role == .separator ? previousFont : font(for: run, bodySize: bodySize, codeSize: code)
            previousFont = font
            var attributes = selection.copyAttributes(forRunAt: index)
            attributes[.font] = font
            attributes[.foregroundColor] = color(for: run, isReasoning: isReasoning, palette: palette,
                                                 tableHeader: tableHeader)
            attributes[.paragraphStyle] = paragraph
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, let url = URL(string: link),
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                attributes[.link] = url
                attributes[.foregroundColor] = palette.native(.link)
            } else if run.inlineCode, !isReasoning {
                attributes[.foregroundColor] = palette.native(.inlineCode)
            }
            // Code blocks get a full-width background instead.
            if run.inlineCode { attributes[.backgroundColor] = palette.native(.inlineCodeBackground) }
            if let math = run.math {
                let size = math.isDisplay ? bodySize * 1.1 : font.pointSize
                if let rendered = renderedMath(math, fontSize: size) {
                    let color = attributes[.foregroundColor] as? NativeColor ?? .mdLabel
                    let piece = NSMutableAttributedString(attachment: mathAttachment(rendered, color: color, source: math.source))
                    piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
                    result.append(piece)
                } else {
                    attributes[.font] = monospaced(math.isDisplay ? code : font.pointSize)
                    if math.isDisplay { attributes[.foregroundColor] = NativeColor.mdSecondary }
                    result.append(NSAttributedString(string: math.source, attributes: attributes))
                }
            } else {
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return Built(text: result, runStarts: starts)
    }

    /// Reasoning keeps the secondary grey throughout; a reply takes the palette's colours.
    private static func color(for run: MarkdownSelection.Run, isReasoning: Bool, palette: MarkdownPalette,
                              tableHeader: Bool) -> NativeColor {
        switch run.role {
        case .codeLanguage: return .mdSecondary
        case .listMarker where run.indents.last != .list(ordered: true): return .mdSecondary
        default:
            if isReasoning { return .mdSecondary }
            if run.isQuoted { return palette.native(.quoteText) }
            if tableHeader || run.role == .tableHeader { return palette.native(.tableHeaderText) }
            if case .heading = run.role { return palette.native(.heading) }
            if run.bold { return palette.native(.bold) }
            return .mdLabel
        }
    }

    private static func paragraphStyle(at index: Int, in runs: [MarkdownSelection.Run],
                                       bodySize: CGFloat) -> NSParagraphStyle {
        let run = runs[index]
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        let indent = MarkdownLayout.width(of: run.indents)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        var before: CGFloat = switch run.gap {
        case .none: 0
        case .block: MarkdownLayout.blockGap
        case .listItem: MarkdownLayout.listItemGap
        }
        // The code background extends below the code; keep the next block clear of it.
        if before > 0, index >= 2, runs[index - 2].role == .code || runs[index - 2].role == .codeLanguage {
            before += MarkdownLayout.codePadding
        }
        switch run.role {
        case .heading(let level) where before > 0:
            before += level <= 2 ? 6 : 2
        case .listMarker:
            // Tabs: the marker right-aligned in its column, then the item text at
            // the hanging indent that wrapped lines also use.
            let outer = MarkdownLayout.width(of: run.indents.dropLast())
            let ordered = run.indents.last == .list(ordered: true)
            style.firstLineHeadIndent = outer
            style.tabStops = [NSTextTab(textAlignment: .right, location: outer + MarkdownLayout.markerColumn(ordered: ordered)),
                              NSTextTab(textAlignment: .left, location: indent)]
        case .codeLanguage:
            style.firstLineHeadIndent = indent + MarkdownLayout.codePadding
            style.headIndent = indent + MarkdownLayout.codePadding
            // Keep the label clear of the Copy button at the end of this line.
            style.tailIndent = -(MarkdownLayout.copyButtonSize.width + MarkdownLayout.codePadding)
            style.minimumLineHeight = MarkdownLayout.copyButtonSize.height
            style.paragraphSpacing = MarkdownLayout.codeHeaderBottom
            if before > 0 { before += MarkdownLayout.codeHeaderTop }
        case .code:
            style.lineSpacing = 2
            style.firstLineHeadIndent = indent + MarkdownLayout.codePadding
            style.headIndent = indent + MarkdownLayout.codePadding
            style.tailIndent = -MarkdownLayout.codePadding
        case .tableHeader, .tableCell:
            style.tabStops = (1...12).map { NSTextTab(textAlignment: .left, location: indent + CGFloat($0) * bodySize * 9) }
        case .math where run.math?.isDisplay == true:
            style.alignment = .center
        default:
            break
        }
        style.paragraphSpacingBefore = before
        return style
    }

    // MARK: Fonts

    /// Text-style sizes relative to body, at the default Dynamic Type size; the
    /// body size passed in already carries the user's scaling.
    private static let ratios: [NativeFont.TextStyle: CGFloat] = {
        let styles: [NativeFont.TextStyle] = [.title2, .title3, .headline, .subheadline, .callout, .caption1]
        #if os(macOS)
        let size = { (style: NativeFont.TextStyle) in NSFont.preferredFont(forTextStyle: style).pointSize }
        #else
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let size = { (style: NativeFont.TextStyle) in UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize }
        #endif
        let body = size(.body)
        return Dictionary(uniqueKeysWithValues: styles.map { ($0, size($0) / body) })
    }()

    private static func size(_ style: NativeFont.TextStyle, bodySize: CGFloat) -> CGFloat {
        (bodySize * (ratios[style] ?? 1)).rounded()
    }

    private static func codeSize(_ bodySize: CGFloat) -> CGFloat { size(.callout, bodySize: bodySize) }

    private static func font(for run: MarkdownSelection.Run, bodySize: CGFloat, codeSize: CGFloat) -> NativeFont {
        var bold = run.bold || run.role == .tableHeader
        let size: CGFloat
        switch run.role {
        case .heading(let level):
            bold = true
            let styles: [Int: NativeFont.TextStyle] = [1: .title2, 2: .title3, 3: .headline]
            size = Self.size(styles[level] ?? .subheadline, bodySize: bodySize)
        case .code: size = codeSize
        case .codeLanguage: return monospaced(Self.size(.caption1, bodySize: bodySize))
        case .listMarker where run.indents.last == .list(ordered: true):
            #if os(macOS)
            return NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular)
            #else
            return UIFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular)
            #endif
        default: size = bodySize
        }
        let base = run.inlineCode || run.role == .code ? monospaced(size) : NativeFont.systemFont(ofSize: size)
        #if os(macOS)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if run.italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
        #else
        var traits = UIFontDescriptor.SymbolicTraits()
        if bold { traits.insert(.traitBold) }
        if run.italic { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    private static func monospaced(_ size: CGFloat) -> NativeFont {
        NativeFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Math

    private static func mathAttachment(_ rendered: MathRenderer.Rendered, color: NativeColor,
                                       source: String) -> NSTextAttachment {
        #if os(macOS)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(rendered: rendered, color: color, source: source)
        return attachment
        #else
        return MathTextAttachment(rendered: rendered, color: color, source: source)
        #endif
    }

    /// Shrinks a formula wider than the space left on its line, so none of it is
    /// clipped. The width comes from the container and the paragraph's indents.
    nonisolated static func fitScale(width: CGFloat, textContainer: NSTextContainer?,
                                     lineFragment: CGRect, characterIndex: Int) -> CGFloat {
        guard let textContainer, width > 0 else { return 1 }
        var available = textContainer.size.width - 2 * textContainer.lineFragmentPadding
        if let storage = textContainer.layoutManager?.textStorage, characterIndex < storage.length,
           let style = storage.attribute(.paragraphStyle, at: characterIndex, effectiveRange: nil) as? NSParagraphStyle {
            available -= max(style.headIndent, style.firstLineHeadIndent)
            if style.tailIndent < 0 { available += style.tailIndent }
        }
        if lineFragment.width > 0 { available = min(available, lineFragment.width) }
        guard available > 1, width > available else { return 1 }
        return available / width
    }
}

/// Code backgrounds, quote bars and code Copy buttons, recomputed from the run
/// offsets on every content update, and placed from live layout when drawn or
/// laid out, so they follow both text changes and resizes.
struct MarkdownDecorations {
    struct Code {
        /// The language line, which also holds the Copy button.
        var header: NSRange
        /// The language line through the end of the code.
        var block: NSRange
        var x: CGFloat
        var copyText: String
    }

    struct Quote {
        var range: NSRange
        var x: CGFloat
    }

    var code: [Code] = []
    var quotes: [Quote] = []

    init() {}

    init(_ selection: MarkdownSelection, runStarts: [Int], length: Int) {
        let runs = selection.runs
        func range(_ index: Int) -> NSRange {
            let end = index + 1 < runStarts.count ? runStarts[index + 1] : length
            return NSRange(location: runStarts[index], length: end - runStarts[index])
        }
        for index in runs.indices {
            let run = runs[index]
            if run.role == .codeLanguage {
                let header = range(index)
                let hasCode = index + 1 < runs.count && runs[index + 1].role == .code
                let block = hasCode ? NSUnionRange(header, range(index + 1)) : header
                code.append(Code(header: header, block: block, x: MarkdownLayout.width(of: run.indents),
                                 copyText: hasCode ? runs[index + 1].copyText : ""))
            }
            for (depth, indent) in run.indents.enumerated() where indent == .quote {
                let x = MarkdownLayout.width(of: run.indents.prefix(depth))
                let part = range(index)
                if let last = quotes.indices.last(where: { quotes[$0].x == x }), NSMaxRange(quotes[last].range) == part.location {
                    quotes[last].range = NSUnionRange(quotes[last].range, part)
                } else {
                    quotes.append(Quote(range: part, x: x))
                }
            }
        }
    }

    /// The top and bottom of the lines holding `range`, in text-container coordinates.
    @MainActor
    static func lineSpan(_ range: NSRange, layoutManager: NSLayoutManager) -> (top: CGFloat, bottom: CGFloat)? {
        guard range.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return (first.minY, last.maxY)
    }

    @MainActor
    func codeRects(layoutManager: NSLayoutManager, width: CGFloat) -> [CGRect] {
        code.map { block in
            guard let span = Self.lineSpan(block.block, layoutManager: layoutManager) else { return .zero }
            let top = span.top - MarkdownLayout.codeHeaderTop
            return CGRect(x: block.x, y: top, width: max(width - block.x, 0),
                          height: span.bottom + MarkdownLayout.codePadding - top)
        }
    }

    @MainActor
    func copyButtonFrames(layoutManager: NSLayoutManager, width: CGFloat) -> [CGRect] {
        let size = MarkdownLayout.copyButtonSize
        return code.map { block in
            guard let span = Self.lineSpan(block.header, layoutManager: layoutManager) else { return .zero }
            return CGRect(x: max(width - size.width - 4, block.x), y: (span.top + span.bottom - size.height) / 2,
                          width: size.width, height: size.height)
        }
    }

    @MainActor
    func quoteBarRects(layoutManager: NSLayoutManager) -> [CGRect] {
        quotes.compactMap { quote in
            guard let span = Self.lineSpan(quote.range, layoutManager: layoutManager) else { return nil }
            return CGRect(x: quote.x, y: span.top, width: MarkdownLayout.quoteBarWidth, height: span.bottom - span.top)
        }
    }

    /// Each quote's tint, from its bar to the end of the line.
    @MainActor
    func quoteBackgroundRects(layoutManager: NSLayoutManager, width: CGFloat) -> [CGRect] {
        quoteBarRects(layoutManager: layoutManager).map { bar in
            CGRect(x: bar.minX, y: bar.minY, width: max(width - bar.minX, 0), height: bar.height)
        }
    }

    /// Room for code padding above a message that starts with a code block, and
    /// below one that ends with it; paragraph spacing cannot provide either.
    static func insets(for runs: [MarkdownSelection.Run]) -> (top: CGFloat, bottom: CGFloat) {
        let top: CGFloat = runs.first?.role == .codeLanguage ? MarkdownLayout.codeHeaderTop : 0
        let bottom: CGFloat = runs.last.map { $0.role == .code || $0.role == .codeLanguage } == true
            ? MarkdownLayout.codePadding : 0
        return (top, bottom)
    }
}

#if os(macOS)
/// Draws a formula as a mask filled with its text colour, resolved in the text
/// view's appearance at draw time, so it follows light/dark changes.
final class MathAttachmentCell: NSTextAttachmentCell {
    let mathImage: NSImage
    let baseline: CGFloat
    let color: NSColor
    let source: String

    init(rendered: MathRenderer.Rendered, color: NSColor, source: String) {
        mathImage = rendered.image
        baseline = rendered.baseline
        self.color = color
        self.source = source
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func cellSize() -> NSSize { mathImage.size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -baseline) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let scale = MarkdownNativeText.fitScale(width: mathImage.size.width, textContainer: textContainer,
                                                lineFragment: lineFrag, characterIndex: charIndex)
        return NSRect(x: 0, y: -baseline * scale, width: mathImage.size.width * scale,
                      height: mathImage.size.height * scale)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let fill = {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.beginTransparencyLayer(in: cellFrame, auxiliaryInfo: nil)
            self.mathImage.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                                respectFlipped: true, hints: nil)
            self.color.setFill()
            cellFrame.fill(using: .sourceAtop)
            context.endTransparencyLayer()
            context.restoreGState()
        }
        if let controlView { controlView.effectiveAppearance.performAsCurrentDrawingAppearance(fill) } else { fill() }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func accessibilityLabel() -> String? { source }
}

/// Read-only, non-scrolling TextKit 1 host. Its copy action uses each run's
/// clipboard spelling (see `MarkdownSelection.copyText(from:range:)`), and
/// native selectAll spans the message.
final class MarkdownSelectionTextView: NSTextView {
    private(set) var selectionModel = MarkdownSelection(document: MarkdownDocument(blocks: []))
    private(set) var appliedBodySize: CGFloat = 0
    private var appliedCodeSize: CGFloat?
    private var appliedReasoning = false
    private(set) var appliedPalette = MarkdownPalette()
    private var appliedTableHeader = false
    private var runStarts: [Int] = []
    private(set) var decorations = MarkdownDecorations()
    private(set) var codeButtons: [NSButton] = []
    private var insets: (top: CGFloat, bottom: CGFloat) = (0, 0)
    private var measured: (width: CGFloat, height: CGFloat)?
    /// Lays the text out at a width other than the view's, for `fittingHeight`.
    private var measuring: (layoutManager: NSLayoutManager, container: NSTextContainer)?
    /// The code backgrounds and quote bars as last drawn or invalidated.
    private var decorationRects: [CGRect] = []
    var messageSource = ""
    var conversationSource: (() -> String)?
    /// Where copies go; tests use a private pasteboard.
    var pasteboard = NSPasteboard.general

    func apply(_ selection: MarkdownSelection, bodySize: CGFloat, codeSize: CGFloat? = nil, isReasoning: Bool,
               palette: MarkdownPalette = MarkdownPalette(), tableHeader: Bool = false) {
        let sizesChanged = bodySize != appliedBodySize || codeSize != appliedCodeSize
        let styleChanged = isReasoning != appliedReasoning || palette != appliedPalette || tableHeader != appliedTableHeader
        guard selection != selectionModel || sizesChanged || styleChanged,
              let storage = textStorage else { return }
        let oldRange = selectedRange()
        if !sizesChanged, !styleChanged {
            // Streaming appends or edits the tail: keep the unchanged leading runs.
            let prefix = zip(selectionModel.runs, selection.runs).prefix { $0 == $1 }.count
            let location = prefix < runStarts.count ? runStarts[prefix] : storage.length
            let tail = MarkdownNativeText.make(selection, from: prefix, bodySize: bodySize, codeSize: codeSize,
                                                    isReasoning: isReasoning, palette: palette, tableHeader: tableHeader)
            storage.replaceCharacters(in: NSRange(location: location, length: storage.length - location), with: tail.text)
            runStarts = Array(runStarts.prefix(prefix)) + tail.runStarts.map { $0 + location }
        } else {
            let built = MarkdownNativeText.make(selection, bodySize: bodySize, codeSize: codeSize, isReasoning: isReasoning,
                                                palette: palette, tableHeader: tableHeader)
            storage.setAttributedString(built.text)
            runStarts = built.runStarts
        }
        selectionModel = selection
        appliedBodySize = bodySize
        appliedCodeSize = codeSize
        appliedReasoning = isReasoning
        let paletteChanged = palette != appliedPalette
        appliedPalette = palette
        appliedTableHeader = tableHeader
        decorations = MarkdownDecorations(selection, runStarts: runStarts, length: storage.length)
        let newInsets = MarkdownDecorations.insets(for: selection.runs)
        let originMoved = newInsets.top != insets.top || paletteChanged
        insets = newInsets
        measured = nil
        updateCodeButtons()
        if oldRange.length > 0, NSMaxRange(oldRange) <= storage.length { setSelectedRange(oldRange) }
        // The text system redraws the edited lines itself. Redraw the decorations
        // only where they moved, rather than repainting (and re-tinting every
        // formula in) the whole message on each streaming delta.
        if originMoved {
            needsDisplay = true
        } else {
            let rects = currentDecorationRects()
            if rects != decorationRects {
                for rect in decorationRects + rects { setNeedsDisplay(rect.insetBy(dx: -1, dy: -1)) }
                decorationRects = rects
            }
        }
    }

    /// The text container has a real width; before the first sizing it is 0,
    /// and laying out then would wrap the message one character per line.
    private var hasLayoutWidth: Bool { (textContainer?.size.width ?? 0) > 1 }

    /// Code backgrounds, then quote backgrounds, then quote bars, in view coordinates.
    private func currentDecorationRects() -> [CGRect] {
        guard hasLayoutWidth, let layoutManager, let textContainer,
              !(decorations.code.isEmpty && decorations.quotes.isEmpty) else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        return (decorations.codeRects(layoutManager: layoutManager, width: bounds.width)
            + decorations.quoteBackgroundRects(layoutManager: layoutManager, width: bounds.width)
            + decorations.quoteBarRects(layoutManager: layoutManager)).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// Height for `width`; layout is only redone when the width or the text changed.
    /// The view itself keeps the width SwiftUI gave it: another width is measured
    /// with a second layout manager on the same text.
    func fittingHeight(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        guard let textStorage, let liveManager = layoutManager, let liveContainer = textContainer else { return 0 }
        // The width it will be placed at (a table cell's column): lay out live at it.
        if let fixedWidth, fixedWidth == width, frame.width != width {
            setFrameSize(NSSize(width: width, height: frame.height))
        }
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        if hasLayoutWidth, abs(liveContainer.size.width - width) < 0.5 {
            (layoutManager, container) = (liveManager, liveContainer)
            detachMeasuring()
        } else {
            if measuring == nil {
                offscreenMeasurements += 1
                let manager = NSLayoutManager()
                let box = NSTextContainer(size: .zero)
                box.lineFragmentPadding = liveContainer.lineFragmentPadding
                manager.addTextContainer(box)
                textStorage.addLayoutManager(manager)
                measuring = (manager, box)
            }
            (layoutManager, container) = measuring!
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height + insets.top + insets.bottom)
        measured = (width, height)
        return height
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: 0, y: insets.top) }

    private func updateCodeButtons() {
        while codeButtons.count > decorations.code.count { codeButtons.removeLast().removeFromSuperview() }
        while codeButtons.count < decorations.code.count {
            let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code") ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(copyCode(_:)))
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.controlSize = .small
            button.toolTip = "Copy code"
            button.setAccessibilityLabel("Copy code")
            addSubview(button)
            codeButtons.append(button)
        }
        for (index, button) in codeButtons.enumerated() { button.tag = index }
        layoutCodeButtons()
    }

    private func layoutCodeButtons() {
        guard !codeButtons.isEmpty, hasLayoutWidth, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        for (button, frame) in zip(codeButtons, decorations.copyButtonFrames(layoutManager: layoutManager, width: bounds.width)) {
            button.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
        }
    }

    /// Code backgrounds as drawn, in view coordinates.
    func codeBackgroundRects() -> [CGRect] {
        guard hasLayoutWidth, let layoutManager, let textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        return decorations.codeRects(layoutManager: layoutManager, width: bounds.width).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        // Placed at a real width: measuring at it uses the live layout from now on.
        if hasLayoutWidth { detachMeasuring() }
        layoutCodeButtons()
    }

    /// Layout managers on this view's text: 1 once placed, 2 while a measurement
    /// at another width is pending.
    var layoutManagerCount: Int { textStorage?.layoutManagers.count ?? 0 }
    /// Times the text was laid out a second time, off screen, to measure a width
    /// the view did not have yet.
    private(set) var offscreenMeasurements = 0
    /// The only width this view is ever placed at, when its container fixes it
    /// (a table cell): measuring at it may size the view itself.
    var fixedWidth: CGFloat?

    /// Drops the second layout manager `fittingHeight` adds for other widths, so
    /// a placed view keeps one layout of its text, not two.
    private func detachMeasuring() {
        guard let measuring else { return }
        textStorage?.removeLayoutManager(measuring.layoutManager)
        self.measuring = nil
    }

    override func layout() {
        super.layout()
        layoutCodeButtons()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Sees every region marked for redraw; tests use it to check what a
    /// streaming delta repaints.
    var invalidationProbe: ((NSRect) -> Void)?

    override var needsDisplay: Bool {
        didSet { if needsDisplay { invalidationProbe?(bounds) } }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidationProbe?(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        invalidationProbe?(rect)
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    override func draw(_ dirtyRect: NSRect) {
        decorationRects = currentDecorationRects()
        if !decorationRects.isEmpty {
            let codeCount = decorations.code.count, quoteCount = decorations.quotes.count
            let code = decorationRects.prefix(codeCount)
            let quoteBackgrounds = decorationRects.dropFirst(codeCount).prefix(quoteCount)
            let quoteBars = decorationRects.dropFirst(codeCount + quoteCount)
            appliedPalette.native(.codeBlockBackground).setFill()
            for rect in code where rect.intersects(dirtyRect) {
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            }
            appliedPalette.native(.quoteBackground).setFill()
            for rect in quoteBackgrounds where rect.intersects(dirtyRect) {
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
            appliedPalette.native(.quoteBar).setFill()
            for rect in quoteBars where rect.intersects(dirtyRect) {
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        super.draw(dirtyRect)
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard decorations.code.indices.contains(sender.tag) else { return }
        Clipboard.copy(decorations.code[sender.tag].copyText, to: pasteboard)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let textStorage else { return }
        Clipboard.copy(MarkdownSelection.copyText(from: textStorage, range: range), to: pasteboard)
    }

    @objc private func copyMessage(_ sender: Any?) { Clipboard.copy(messageSource, to: pasteboard) }
    @objc private func copyConversation(_ sender: Any?) { Clipboard.copy(conversationSource?() ?? "", to: pasteboard) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard conversationSource != nil else { return menu }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Message", action: #selector(copyMessage(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Conversation", action: #selector(copyConversation(_:)), keyEquivalent: "").target = self
        return menu
    }
}

struct SelectableMarkdownText: NSViewRepresentable {
    let selection: MarkdownSelection
    let source: String
    let bodySize: CGFloat
    let isReasoning: Bool
    let conversationSource: (() -> String)?
    /// The width the view will be placed at, when the caller already fixes it
    /// (table cells): it measures with its own layout and never needs a second one.
    var width: CGFloat? = nil
    /// Code blocks inside the prose (in a list or quote); nil keeps callout's ratio.
    var codeSize: CGFloat? = nil
    /// A table's header row, in the palette's header colour.
    var tableHeader = false
    @Environment(\.markdownPalette) private var palette
    @Environment(\.markdownPreviewScheme) private var previewScheme

    func makeNSView(context: Context) -> MarkdownSelectionTextView {
        MarkdownSelectionTextView.make()
    }

    func updateNSView(_ view: MarkdownSelectionTextView, context: Context) {
        view.fixedWidth = width
        view.messageSource = source
        view.conversationSource = conversationSource
        let appearance = previewScheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        view.apply(selection, bodySize: bodySize, codeSize: codeSize, isReasoning: isReasoning,
                   palette: palette, tableHeader: tableHeader)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownSelectionTextView, context: Context) -> CGSize? {
        // A known width is the answer whatever is proposed: a Grid asks for ideal
        // sizes (no width) too, and measuring those at 400 pt would lay the text
        // out a second time.
        let width = self.width ?? MarkdownSelectionTextView.measuringWidth(proposal.width)
        return CGSize(width: width, height: max(nsView.fittingHeight(width: width), bodySize))
    }
}

extension MarkdownSelectionTextView {
    /// A nil or unbounded proposal asks for the ideal size: measure at 400 pt.
    static func measuringWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return 400 }
        return max(proposed, 1)
    }

    static func make() -> MarkdownSelectionTextView {
        // TextKit 1 from the start: the decorations and math use NSLayoutManager.
        let view = MarkdownSelectionTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        // Links keep the theme's link colour (each run's foreground): the default link
        // attributes paint every link the system's blue.
        view.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // SwiftUI owns the frame; the height comes from `sizeThatFits`.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
}
#else
/// Draws a formula filled with its text colour, resolved for the traits current
/// while drawing, so it follows light/dark changes.
final class MathTextAttachment: NSTextAttachment {
    private let mathImage: UIImage
    private let baseline: CGFloat
    private let color: UIColor

    @MainActor
    init(rendered: MathRenderer.Rendered, color: UIColor, source: String) {
        mathImage = rendered.image
        baseline = rendered.baseline
        self.color = color
        super.init(data: nil, ofType: nil)
        image = rendered.image
        accessibilityLabel = source
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let scale = MarkdownNativeText.fitScale(width: mathImage.size.width, textContainer: textContainer,
                                                lineFragment: lineFrag, characterIndex: charIndex)
        return CGRect(x: 0, y: -baseline * scale, width: mathImage.size.width * scale,
                      height: mathImage.size.height * scale)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> UIImage? {
        mathImage.withTintColor(color.resolvedColor(with: UITraitCollection.current), renderingMode: .alwaysOriginal)
    }
}

final class MarkdownSelectionTextView: UITextView {
    /// A TextKit 1 view built through `init(frame:textContainer:)`.
    ///
    /// Not `init(usingTextLayoutManager: false)`: on iOS 27 that left this subclass's
    /// stored properties uninitialised, and the first `apply` crashed reading
    /// `selectionModel` (SIGSEGV in `Array ==`, seen in the simulator, 2026-10).
    static func textKit1() -> MarkdownSelectionTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = MarkdownSelectionTextView(frame: .zero, textContainer: container)
        view.ownedStorage = storage
        return view
    }

    /// The text system's root: the layout manager and container only reference it weakly.
    private var ownedStorage: NSTextStorage?
    private(set) var selectionModel = MarkdownSelection(document: MarkdownDocument(blocks: []))
    private(set) var appliedBodySize: CGFloat = 0
    private var appliedCodeSize: CGFloat?
    private var appliedReasoning = false
    private var appliedPalette = MarkdownPalette()
    private var appliedTableHeader = false
    private var runStarts: [Int] = []
    private(set) var decorations = MarkdownDecorations()
    private var codeButtons: [UIButton] = []
    private var codeBackgrounds: [UIView] = []
    private var quoteBackgrounds: [UIView] = []
    private var quoteBars: [UIView] = []
    private var measured: (width: CGFloat, height: CGFloat)?

    func apply(_ selection: MarkdownSelection, bodySize: CGFloat, codeSize: CGFloat? = nil, isReasoning: Bool,
               palette: MarkdownPalette = MarkdownPalette(), tableHeader: Bool = false) {
        let sizesChanged = bodySize != appliedBodySize || codeSize != appliedCodeSize
        let styleChanged = isReasoning != appliedReasoning || palette != appliedPalette || tableHeader != appliedTableHeader
        guard selection != selectionModel || sizesChanged || styleChanged else { return }
        let oldRange = selectedRange
        if !sizesChanged, !styleChanged {
            // Streaming appends or edits the tail: keep the unchanged leading runs.
            let prefix = zip(selectionModel.runs, selection.runs).prefix { $0 == $1 }.count
            let location = prefix < runStarts.count ? runStarts[prefix] : textStorage.length
            let tail = MarkdownNativeText.make(selection, from: prefix, bodySize: bodySize, codeSize: codeSize,
                                                    isReasoning: isReasoning, palette: palette, tableHeader: tableHeader)
            textStorage.replaceCharacters(in: NSRange(location: location, length: textStorage.length - location), with: tail.text)
            runStarts = Array(runStarts.prefix(prefix)) + tail.runStarts.map { $0 + location }
        } else {
            let built = MarkdownNativeText.make(selection, bodySize: bodySize, codeSize: codeSize, isReasoning: isReasoning,
                                                palette: palette, tableHeader: tableHeader)
            attributedText = built.text
            runStarts = built.runStarts
        }
        selectionModel = selection
        appliedBodySize = bodySize
        appliedCodeSize = codeSize
        appliedReasoning = isReasoning
        appliedPalette = palette
        appliedTableHeader = tableHeader
        decorations = MarkdownDecorations(selection, runStarts: runStarts, length: textStorage.length)
        let insets = MarkdownDecorations.insets(for: selection.runs)
        textContainerInset = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        measured = nil
        updateDecorationViews()
        if oldRange.length > 0, NSMaxRange(oldRange) <= textStorage.length { selectedRange = oldRange }
    }

    /// Height for `width`; layout is only redone when the width or the text changed.
    func fittingHeight(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        measured = (width, height)
        return height
    }

    func observeAppearance() {
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MarkdownSelectionTextView, _: UITraitCollection) in
            // Math images are tinted when drawn; draw them again in the new style.
            view.layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: view.textStorage.length))
        }
    }

    private func updateDecorationViews() {
        func resize<View: UIView>(_ views: inout [View], to count: Int, make: () -> View) {
            while views.count > count { views.removeLast().removeFromSuperview() }
            while views.count < count { views.append(make()) }
        }
        resize(&codeBackgrounds, to: decorations.code.count) {
            let view = UIView()
            view.layer.cornerRadius = 8
            view.isUserInteractionEnabled = false
            insertSubview(view, at: 0)
            return view
        }
        resize(&quoteBars, to: decorations.quotes.count) {
            let view = UIView()
            view.layer.cornerRadius = 1.5
            view.isUserInteractionEnabled = false
            insertSubview(view, at: 0)
            return view
        }
        resize(&quoteBackgrounds, to: decorations.quotes.count) {
            let view = UIView()
            view.layer.cornerRadius = 1.5
            view.isUserInteractionEnabled = false
            insertSubview(view, at: 0)
            return view
        }
        for view in codeBackgrounds { view.backgroundColor = appliedPalette.native(.codeBlockBackground) }
        for view in quoteBackgrounds { view.backgroundColor = appliedPalette.native(.quoteBackground) }
        for view in quoteBars { view.backgroundColor = appliedPalette.native(.quoteBar) }
        resize(&codeButtons, to: decorations.code.count) {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "doc.on.doc")
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption1)
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = "Copy code"
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button, let index = self.codeButtons.firstIndex(of: button),
                      self.decorations.code.indices.contains(index) else { return }
                Clipboard.copy(self.decorations.code[index].copyText)
            }, for: .touchUpInside)
            addSubview(button)
            return button
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Before the first sizing the container is 0 wide: laying out then would
        // wrap the message one character per line.
        guard !(decorations.code.isEmpty && decorations.quotes.isEmpty), textContainer.size.width > 1 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let top = textContainerInset.top
        for (view, rect) in zip(codeBackgrounds, decorations.codeRects(layoutManager: layoutManager, width: bounds.width)) {
            view.frame = rect.offsetBy(dx: 0, dy: top)
        }
        for (button, rect) in zip(codeButtons, decorations.copyButtonFrames(layoutManager: layoutManager, width: bounds.width)) {
            button.frame = rect.offsetBy(dx: 0, dy: top)
        }
        for (view, rect) in zip(quoteBars, decorations.quoteBarRects(layoutManager: layoutManager)) {
            view.frame = rect.offsetBy(dx: 0, dy: top)
        }
        for (view, rect) in zip(quoteBackgrounds, decorations.quoteBackgroundRects(layoutManager: layoutManager, width: bounds.width)) {
            view.frame = rect.offsetBy(dx: 0, dy: top)
        }
    }

    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange else { return }
        let start = offset(from: beginningOfDocument, to: range.start)
        let end = offset(from: beginningOfDocument, to: range.end)
        Clipboard.copy(MarkdownSelection.copyText(from: attributedText, range: NSRange(location: start, length: end - start)))
    }
}

struct SelectableMarkdownText: UIViewRepresentable {
    let selection: MarkdownSelection
    let source: String
    let bodySize: CGFloat
    let isReasoning: Bool
    let conversationSource: (() -> String)?
    /// The width the view will be placed at, when the caller already knows it.
    var width: CGFloat? = nil
    /// Code blocks inside the prose (in a list or quote); nil keeps callout's ratio.
    var codeSize: CGFloat? = nil
    /// A table's header row, in the palette's header colour.
    var tableHeader = false
    @Environment(\.markdownPalette) private var palette
    @Environment(\.markdownPreviewScheme) private var previewScheme

    func makeUIView(context: Context) -> MarkdownSelectionTextView {
        // TextKit 1 from the start: the decorations and math use NSLayoutManager.
        let view = MarkdownSelectionTextView.textKit1()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        // Links keep the theme's link colour (each run's foreground), not the tint.
        view.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.observeAppearance()
        if let width { view.frame.size.width = width }
        return view
    }

    func updateUIView(_ view: MarkdownSelectionTextView, context: Context) {
        let style: UIUserInterfaceStyle = switch previewScheme {
        case .dark?: .dark
        case .light?: .light
        default: .unspecified
        }
        if view.overrideUserInterfaceStyle != style { view.overrideUserInterfaceStyle = style }
        view.apply(selection, bodySize: bodySize, codeSize: codeSize, isReasoning: isReasoning,
                   palette: palette, tableHeader: tableHeader)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownSelectionTextView, context: Context) -> CGSize? {
        // A known width is the answer whatever is proposed; otherwise a nil or
        // unbounded proposal asks for the ideal size: measure at 400 pt.
        let width = self.width ?? proposal.width.flatMap { $0.isFinite ? max($0, 1) : nil } ?? 400
        return CGSize(width: width, height: max(uiView.fittingHeight(width: width), bodySize))
    }
}
#endif
