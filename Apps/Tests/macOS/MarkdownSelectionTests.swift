import AppKit
import HermesKit
import SwiftUI
import Testing

/// One assistant message as one native text view: selection and copy, and its
/// rendering against the former one-view-per-block layout.
@MainActor
@Suite struct MarkdownSelectionHostTests {
    private let source = """
    # Title

    First paragraph with $x$.

    Second paragraph.

    - one
    - two

    ```swift
    let answer = 42
    ```

    | Name | Value |
    |------|-------|
    | a | b |

    $$x^2$$
    """

    private static let wideFormula = "\\sum_{i=1}^{n} a_i + b_i + c_i + d_i + e_i + f_i + g_i + h_i + j_i + k_i + l_i + m_i + n_i + o_i + p_i + q_i + r_i"

    @MainActor private final class Hosted {
        let host: NSHostingView<MarkdownView>
        let view: MarkdownSelectionTextView

        init(host: NSHostingView<MarkdownView>, view: MarkdownSelectionTextView) {
            self.host = host
            self.view = view
        }

        var layoutManager: NSLayoutManager { view.layoutManager! }
        var storage: NSTextStorage { view.textStorage! }
        var string: NSString { view.string as NSString }

        func update(_ text: String, streaming: Bool = false) {
            host.rootView = MarkdownView(text: text, isStreaming: streaming)
            host.layoutSubtreeIfNeeded()
        }

        func resize(width: CGFloat) {
            host.frame.size.width = width
            host.layoutSubtreeIfNeeded()
        }

        /// The used rect of the line holding `index`, in view coordinates.
        func lineRect(at index: Int) -> CGRect {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let origin = view.textContainerOrigin
            return layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: origin.x, dy: origin.y)
        }

        /// The x where the glyph for `index` is drawn.
        func glyphX(at index: Int) -> CGFloat {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return line.minX + layoutManager.location(forGlyphAt: glyph).x
        }

        func glyphRect(at index: Int) -> CGRect {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            let origin = view.textContainerOrigin
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
                .offsetBy(dx: origin.x, dy: origin.y)
        }

        var attachmentIndices: [Int] {
            var result: [Int] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil { result.append(range.location) }
            }
            return result
        }
    }

    private func host(_ text: String, width: CGFloat = 600, streaming: Bool = false, reasoning: Bool = false,
                      appearance: NSAppearance.Name? = nil) throws -> Hosted {
        let host = NSHostingView(rootView: MarkdownView(text: text, isStreaming: streaming, isReasoning: reasoning))
        if let appearance { host.appearance = NSAppearance(named: appearance) }
        host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        host.layoutSubtreeIfNeeded()
        return Hosted(host: host, view: try #require(findTextView(in: host)))
    }

    private func findTextView(in view: NSView) -> MarkdownSelectionTextView? {
        if let text = view as? MarkdownSelectionTextView { return text }
        for child in view.subviews {
            if let found = findTextView(in: child) { return found }
        }
        return nil
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("hermes.tests.\(UUID().uuidString)"))
    }

    // MARK: Selection and copy

    @Test func crossBlockCopyAndSelectAll() throws {
        let hosted = try host(source)
        let view = hosted.view
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        view.pasteboard = pasteboard
        let generalCount = NSPasteboard.general.changeCount

        let first = hosted.string.range(of: "First paragraph").location
        let lastFormula = try #require(hosted.attachmentIndices.last)
        view.setSelectedRange(NSRange(location: first, length: lastFormula + 1 - first))
        view.copy(nil)
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.hasPrefix("First paragraph with $x$.\n\nSecond paragraph.\n\n- one\n- two\n\nlet answer = 42\n\n"))
        #expect(copied.contains("Name\tValue\na\tb"))
        #expect(copied.hasSuffix("\n\n$$x^2$$"))

        view.selectAll(nil)
        #expect(view.selectedRange() == NSRange(location: 0, length: hosted.storage.length))
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == MarkdownSelection(parsing: source).plainText)

        let codeButton = try #require(view.codeButtons.first)
        codeButton.performClick(nil)
        #expect(pasteboard.string(forType: .string) == "let answer = 42")
        #expect(NSPasteboard.general.changeCount == generalCount)
    }

    /// The renderer's own output, through the copy function the text view uses.
    @Test func copyOfRenderedTextUsesEachRunsClipboardSpelling() {
        let selection = MarkdownSelection(parsing: source)
        let rendered = MarkdownNativeText.make(selection, bodySize: 13).text
        #expect(rendered.containsAttachments)
        #expect(MarkdownSelection.copyText(from: rendered, range: NSRange(location: 0, length: rendered.length))
                == selection.plainText)
        #expect(selection.plainText.contains("$x$") && selection.plainText.hasSuffix("$$x^2$$"))
    }

    // MARK: 1. Math colour and accessibility

    /// The brightest and darkest pixels drawn for the first formula over an
    /// opaque `background`, as the transcript would show it.
    private func mathPixels(_ hosted: Hosted, over background: NSColor) throws -> (brightest: CGFloat, darkest: CGFloat) {
        let view = hosted.view
        let index = try #require(hosted.attachmentIndices.first)
        let rect = hosted.glyphRect(at: index)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var brightest: CGFloat = 0, darkest: CGFloat = 1
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                brightest = max(brightest, color.brightnessComponent)
                darkest = min(darkest, color.brightnessComponent)
            }
        }
        return (brightest, darkest)
    }

    @Test func mathFollowsTextColourAndAppearanceChanges() throws {
        let hosted = try host("$$x^2 + y^2$$", appearance: .darkAqua)
        #expect(try mathPixels(hosted, over: .black).brightest > 0.7, "math must be light on a dark background")

        hosted.host.appearance = NSAppearance(named: .aqua)
        hosted.host.layoutSubtreeIfNeeded()
        #expect(try mathPixels(hosted, over: .white).darkest < 0.3, "math must be dark on a light background")
    }

    @Test func reasoningMathUsesTheSecondaryColour() throws {
        let hosted = try host("Then $x^2 + y^2$ follows.", reasoning: true, appearance: .darkAqua)
        let pixels = try mathPixels(hosted, over: .black)
        #expect(pixels.brightest > 0.4, "secondary math must show on a dark background")
        #expect(pixels.brightest < 0.75, "reasoning math uses the secondary colour, not the label colour")
    }

    @Test func mathReadsItsSourceToVoiceOver() throws {
        let hosted = try host("Inline $a+b$ and\n\n$$x^2$$")
        let labels = hosted.attachmentIndices.compactMap { index -> String? in
            let attachment = hosted.storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
            return (attachment?.attachmentCell as? MathAttachmentCell)?.accessibilityLabel()
        }
        #expect(labels == ["a+b", "x^2"])
    }

    // MARK: 2. Wide display math

    @Test func wideFormulaShrinksToTheColumn() throws {
        let rendered = try #require(MathRenderer.render(Self.wideFormula, fontSize: 13 * 1.1, display: true))
        #expect(rendered.image.size.width > 300, "the formula must be wider than the column to test anything")

        let hosted = try host("Intro.\n\n$$\(Self.wideFormula)$$\n\n- item $\(Self.wideFormula)$", width: 300)
        #expect(hosted.attachmentIndices.count == 2)
        for index in hosted.attachmentIndices {
            // The laid-out attachment, not its bounding rect (which TextKit clips to the line).
            let glyph = hosted.layoutManager.glyphIndexForCharacter(at: index)
            let size = hosted.layoutManager.attachmentSize(forGlyphAt: glyph)
            let x = hosted.glyphX(at: index)
            #expect(size.width > 0)
            #expect(x >= -0.5)
            #expect(x + size.width <= hosted.view.bounds.width + 0.5, "formula from \(x) of width \(size.width) is clipped")
        }
    }

    // MARK: 3. Unclosed math while streaming

    @Test func unclosedDisplayMathShowsItsSourceWhileStreaming() throws {
        let hosted = try host("$$\\frac{a}{", streaming: true)
        for partial in ["$$\\frac{a}{", "$$\\frac{a}{b}", "$$\\frac{a}{b}+\\sqrt{", "$$\\frac{a}{b}+\\sqrt{2}"] {
            hosted.update(partial, streaming: true)
            #expect(hosted.attachmentIndices.isEmpty, "\(partial) rendered as an image")
            #expect(hosted.view.string == String(partial.dropFirst(2)))
        }
        hosted.update("$$\\frac{a}{b}+\\sqrt{2}$$", streaming: true)
        #expect(hosted.attachmentIndices.count == 1)
    }

    // MARK: 4. Code Copy button and language label

    @Test func codeCopyButtonSitsOnTheLanguageLineClearOfTheCode() throws {
        let code = "let aVeryLongIdentifierName = anotherVeryLongFunctionName(argument, other)"
        let hosted = try host("Intro.\n\n```swift\n\(code)\n```", width: 300)
        let button = try #require(hosted.view.codeButtons.first)
        let label = hosted.string.range(of: "swift")
        #expect(label.location != NSNotFound, "the language label is shown")
        let codeStart = hosted.string.range(of: "let aVery").location
        let firstCodeLine = hosted.lineRect(at: codeStart)
        #expect(!button.frame.intersects(firstCodeLine), "button \(button.frame) covers code line \(firstCodeLine)")
        let labelLine = hosted.lineRect(at: label.location)
        #expect(button.frame.minY < labelLine.maxY && button.frame.maxY > labelLine.minY, "button is not on the label line")
        #expect(!button.frame.intersects(hosted.glyphRect(at: NSMaxRange(label) - 1)))
    }

    // MARK: 5. Rendering parity

    @Test func listsUseBulletsHangingIndentAndNesting() throws {
        let long = "a long item that certainly wraps onto a second line in a narrow column of text"
        let markdown = "- one\n- \(long)\n  - nested\n- [x] done\n- [ ] todo\n\n1. first"
        let hosted = try host(markdown, width: 300)
        let string = hosted.string
        for marker in ["•", "◦", "☑", "☐", "1."] {
            #expect(string.range(of: marker).location != NSNotFound, "missing \(marker)")
        }
        #expect(string.range(of: "- ").location == NSNotFound)

        let start = string.range(of: "a long item").location
        var firstLine = NSRange()
        hosted.layoutManager.lineFragmentRect(forGlyphAt: hosted.layoutManager.glyphIndexForCharacter(at: start),
                                              effectiveRange: &firstLine)
        let secondLineStart = hosted.layoutManager.characterIndexForGlyph(at: NSMaxRange(firstLine))
        #expect(secondLineStart < string.range(of: "nested").location, "the long item must wrap")
        #expect(abs(hosted.glyphX(at: secondLineStart) - hosted.glyphX(at: start)) < 0.5, "wrapped line is not under the text")
        #expect(hosted.glyphX(at: start) > hosted.glyphX(at: string.range(of: "•").location))
        #expect(hosted.glyphX(at: string.range(of: "nested").location) > hosted.glyphX(at: start) + 10)

        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        hosted.view.pasteboard = pasteboard
        hosted.view.selectAll(nil)
        hosted.view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "- one\n- \(long)\n  - nested\n- [x] done\n- [ ] todo\n\n1. first")
    }

    @Test func headingSizesAndWeightsMatchTheTextStyles() throws {
        let hosted = try host("# H1\n\n## H2\n\n### H3\n\n#### H4\n\n##### H5\n\n###### H6\n\nBody")
        func font(_ text: String) throws -> NSFont {
            let index = hosted.string.range(of: text).location
            return try #require(hosted.storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        }
        let expected: [(String, NSFont.TextStyle)] = [("H1", .title2), ("H2", .title3), ("H3", .headline),
                                                       ("H4", .subheadline), ("H5", .subheadline), ("H6", .subheadline)]
        for (text, style) in expected {
            let font = try font(text)
            #expect(font.pointSize == NSFont.preferredFont(forTextStyle: style).pointSize, "\(text) size")
            #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "\(text) is not bold")
        }
        #expect(try font("Body").pointSize == 13)
    }

    @Test func tableHeaderIsBold() throws {
        let hosted = try host("| Name | Value |\n|---|---|\n| cell1 | cell2 |")
        func isBold(_ text: String) -> Bool {
            let index = hosted.string.range(of: text).location
            let font = hosted.storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            return font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        }
        #expect(isBold("Name"))
        #expect(!isBold("cell1"))
    }

    @Test func blockQuoteIsIndentedWithABarNotPrefixed() throws {
        let hosted = try host("Before.\n\n> quoted text\n> more\n\nAfter.")
        #expect(hosted.string.range(of: ">").location == NSNotFound)
        let quoted = hosted.string.range(of: "quoted").location
        #expect(hosted.glyphX(at: quoted) >= 12)
        #expect(hosted.glyphX(at: hosted.string.range(of: "After").location) == 0)
        let bars = hosted.view.decorations.quoteBarRects(layoutManager: hosted.layoutManager)
        #expect(bars.count == 1)
        let line = hosted.lineRect(at: quoted)
        #expect(bars.first.map { $0.minX < hosted.glyphX(at: quoted) && $0.minY <= line.midY && $0.maxY >= line.midY } == true)
    }

    @Test func blocksAreSeparatedBySpacingNotABlankLine() throws {
        let hosted = try host("First.\n\nSecond.")
        #expect(hosted.view.string == "First.\nSecond.")
        let first = hosted.lineRect(at: 0)
        let second = hosted.lineRect(at: hosted.string.range(of: "Second").location)
        #expect(abs(second.minY - first.maxY - 10) <= 1.5, "gap \(second.minY - first.maxY)")
    }

    @Test func hiddenMessageCopyButtonAddsNoHeight() {
        let plain = NSHostingView(rootView: Text("Hello").padding(10))
        let gutter = NSHostingView(rootView: Text("Hello").padding(10)
            .messageCopyAccessory(isHovering: false, placement: .trailingGutter(.bottom)) {})
        let centered = NSHostingView(rootView: Text("Hello").padding(10)
            .messageCopyAccessory(isHovering: false, placement: .trailingGutter(.center)) {})
        let user = NSHostingView(rootView: Text("Hello").padding(10)
            .messageCopyAccessory(isHovering: false, placement: .leadingOutside) {})
        #expect(gutter.fittingSize.height == plain.fittingSize.height)
        #expect(centered.fittingSize.height == plain.fittingSize.height)
        #expect(user.fittingSize.height == plain.fittingSize.height)
        #expect(user.fittingSize.width == plain.fittingSize.width)
    }

    // MARK: 6. Decorations follow the text

    @Test func codeBackgroundAndButtonFollowEarlierTextAndResizes() throws {
        let markdown = "A\n\n```\ncode\n```"
        let hosted = try host(markdown)
        let longer = String(repeating: "Words that wrap. ", count: 60) + "\n\n```\ncode\n```"
        hosted.update(longer)
        try expectDecorationsTrackCode(hosted)

        hosted.resize(width: 300)
        try expectDecorationsTrackCode(hosted)
        hosted.resize(width: 700)
        try expectDecorationsTrackCode(hosted)
    }

    private func expectDecorationsTrackCode(_ hosted: Hosted, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let background = try #require(hosted.view.codeBackgroundRects().first, sourceLocation: sourceLocation)
        let button = try #require(hosted.view.codeButtons.first, sourceLocation: sourceLocation)
        let code = hosted.lineRect(at: hosted.string.range(of: "code").location)
        #expect(background.contains(CGRect(x: code.minX, y: code.minY, width: 1, height: code.height)),
                "background \(background) misses code \(code)", sourceLocation: sourceLocation)
        #expect(background.minY > hosted.lineRect(at: 0).minY, sourceLocation: sourceLocation)
        #expect(button.frame.maxY <= code.minY && button.frame.minY >= background.minY,
                "button \(button.frame) not above code \(code)", sourceLocation: sourceLocation)
        #expect(abs(button.frame.maxX - (hosted.view.bounds.width - 4)) < 0.5, sourceLocation: sourceLocation)
    }

    // MARK: Also

    @Test func onlyInlineCodeGetsALineBackground() throws {
        let hosted = try host("Use `inline` here.\n\n```\nblock\n```")
        let inline = hosted.string.range(of: "inline").location
        let block = hosted.string.range(of: "block").location
        #expect(hosted.storage.attribute(.backgroundColor, at: inline, effectiveRange: nil) != nil)
        #expect(hosted.storage.attribute(.backgroundColor, at: block, effectiveRange: nil) == nil)
    }

    @MainActor private final class Flag { var value = false }

    /// A TextKit 2 view would switch to TextKit 1 on its first `layoutManager` use.
    @Test func usesTextKit1FromTheStart() throws {
        let switched = Flag()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { switched.value = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let hosted = try host("Hello\n\n```\ncode\n```")
        #expect(!switched.value)
        #expect(hosted.view.textLayoutManager == nil)
    }

    @Test func streamingCodeReusesItsCopyButton() throws {
        let hosted = try host("```swift\nlet a", streaming: true)
        let button = try #require(hosted.view.codeButtons.first)
        hosted.update("```swift\nlet a = 1\nlet b", streaming: true)
        #expect(hosted.view.codeButtons.count == 1)
        #expect(hosted.view.codeButtons.first === button)
        hosted.update("```swift\nlet a = 1\nlet b = 2\n```\n\nDone.\n\n```\nmore", streaming: true)
        #expect(hosted.view.codeButtons.count == 2)
        #expect(hosted.view.codeButtons.first === button)
    }

    // MARK: Round 2. The per-message copy button stays off the text

    /// A row drawn on white in light mode, as the transcript would show it.
    private func render(width: CGFloat, @ViewBuilder _ content: () -> some View) throws -> (host: NSView, rep: NSBitmapImageRep) {
        let host = NSHostingView(rootView: content().frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.frame.size.height = host.fittingSize.height
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (host, rep)
    }

    /// The bounding box, in points, of pixels where `test` holds.
    private func box(_ rep: NSBitmapImageRep, width: CGFloat, where test: (Int, Int) -> Bool) -> CGRect? {
        let scale = CGFloat(rep.pixelsWide) / width
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where test(x, y) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func brightness(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
    }

    /// Where the visible copy button is drawn (hover on against hover off), and
    /// the box holding all of the row's own ink (text, icons) with hover off.
    private func copyButtonAndInk(width: CGFloat, row: (Bool) -> some View) throws
        -> (button: CGRect, ink: CGRect, off: (host: NSView, rep: NSBitmapImageRep)) {
        let off = try render(width: width) { row(false) }
        let on = try render(width: width) { row(true) }
        #expect(on.rep.pixelsWide == off.rep.pixelsWide && on.rep.pixelsHigh == off.rep.pixelsHigh,
                "showing the button must not change the row's size")
        let button = try #require(box(on.rep, width: width) { x, y in
            abs(brightness(on.rep, x, y) - brightness(off.rep, x, y)) > 0.08
        }, "hover on draws no button")
        let ink = try #require(box(off.rep, width: width) { x, y in brightness(off.rep, x, y) < 0.6 })
        return (button, ink, off)
    }

    @Test func replyCopyButtonStaysClearOfTheText() throws {
        let code = String(repeating: "let value = compute(argument) + other; ", count: 4)
        var item = TranscriptItem(id: "a", role: .assistant, text: "Answer.\n\n```swift\n\(code)\n```")
        item.isActive = false
        let result = try copyButtonAndInk(width: 460) { AssistantMessageContent(item: item, isHovering: $0) {} }
        #expect(result.button.minX >= result.ink.maxX, "copy button \(result.button) overlaps text ink \(result.ink)")

        // The whole width of the reply's last line, as if text ran to its end.
        let view = try #require(findTextView(in: result.off.host))
        let layoutManager = try #require(view.layoutManager)
        let lastGlyph = layoutManager.glyphIndexForCharacter(at: (view.string as NSString).length - 1)
        let lastLine = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let line = view.convert(lastLine, to: result.off.host)
        #expect(lastLine.width > 300)
        #expect(!result.button.intersects(line), "copy button \(result.button) covers the last line \(line)")
        #expect(!result.button.intersects(view.convert(view.bounds, to: result.off.host)), "copy button is over the message")
    }

    @Test func toolCopyButtonStaysClearOfTheDetail() throws {
        var item = TranscriptItem(id: "t", role: .tool, text: "")
        item.toolName = "search"
        item.detail = String(repeating: "a long tool detail that wraps across the card ", count: 6)
        let result = try copyButtonAndInk(width: 420) { ToolMessageContent(item: item, isHovering: $0) {} }
        #expect(result.ink.width > 300, "the detail must run across the card to test anything")
        #expect(result.button.minX >= result.ink.maxX, "copy button \(result.button) overlaps the detail \(result.ink)")
    }

    // MARK: Round 2. Streaming cost

    @MainActor private final class Rects { var all: [CGRect] = [] }

    /// A delta that only changes text after a code block leaves the block's
    /// background, and the formula before it, out of the redraw.
    @Test func deltaRedrawsOnlyWhatChanged() throws {
        let before = "Intro $x^2$.\n\n```\ncode\n```\n\nTail a"
        let hosted = try host(before, streaming: true)
        let view = hosted.view
        #expect(!view.codeBackgroundRects().isEmpty)
        let formula = hosted.glyphRect(at: try #require(hosted.attachmentIndices.first))
        // Shown once, as a message is before its next delta arrives.
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let invalidated = Rects()
        view.invalidationProbe = { invalidated.all.append($0) }
        defer { view.invalidationProbe = nil }

        hosted.update(before + "b", streaming: true)
        let tailLine = hosted.lineRect(at: hosted.string.range(of: "Tail").location)
        #expect(invalidated.all.contains { $0.intersects(tailLine) }, "the edited line must redraw")
        // The edited line's own redraw reaches up through its paragraph spacing
        // into the code block's bottom padding; the code itself stays untouched.
        let codeLine = hosted.lineRect(at: hosted.string.range(of: "code").location)
        #expect(!invalidated.all.contains { $0.intersects(codeLine) },
                "the unchanged code was invalidated: \(invalidated.all)")
        #expect(!invalidated.all.contains { $0.intersects(formula) }, "the unchanged formula was invalidated")
        #expect(!invalidated.all.contains { $0.height >= view.bounds.height }, "the whole view was invalidated")

        // Most deltas inside a code block keep its height: the code run redraws (it
        // is replaced whole), nothing before it does, and the view is not repainted.
        hosted.update("Intro $x^2$.\n\n```\ncode\nmore", streaming: true)
        view.cacheDisplay(in: view.bounds, to: rep)
        invalidated.all = []
        hosted.update("Intro $x^2$.\n\n```\ncode\nmore code", streaming: true)
        let lastCodeLine = hosted.lineRect(at: hosted.string.range(of: "more").location)
        #expect(invalidated.all.contains { $0.intersects(lastCodeLine) })
        #expect(!invalidated.all.contains { $0.intersects(formula) || $0.height >= view.bounds.height },
                "unchanged lines were invalidated: \(invalidated.all)")

        // A delta that adds a line grows the background, which redraws. (The view's
        // height changes too, and AppKit then redraws it all, once per added line.)
        let short = try #require(view.codeBackgroundRects().first)
        invalidated.all = []
        hosted.update("Intro $x^2$.\n\n```\ncode\nmore code\nanother line", streaming: true)
        let grown = try #require(view.codeBackgroundRects().first)
        #expect(grown.height > short.height)
        #expect(invalidated.all.contains { $0.contains(CGPoint(x: grown.maxX - 3, y: grown.maxY - 3)) })
    }

    @Test func noLayoutBeforeTheFirstSizing() throws {
        let view = MarkdownSelectionTextView.make()
        view.apply(MarkdownSelection(parsing: "Intro\n\n> quote\n\n```\ncode\n```"), bodySize: 13, isReasoning: false)
        let layoutManager = try #require(view.layoutManager)
        #expect(layoutManager.firstUnlaidCharacterIndex() == 0, "laid out at zero width")
        view.setFrameSize(NSSize(width: 300, height: 200))
        #expect(view.codeButtons.first?.frame.width ?? 0 > 0)
        #expect(view.codeBackgroundRects().first?.width == 300)
    }

    @Test func measuringLeavesTheViewAtItsWidth() throws {
        let hosted = try host(String(repeating: "Words that wrap at narrower widths. ", count: 20), width: 600)
        let view = hosted.view
        let width = view.frame.width
        let wide = view.fittingHeight(width: width)
        let narrow = view.fittingHeight(width: 300)
        #expect(view.frame.width == width)
        #expect(view.textContainer?.size.width == width)
        #expect(narrow > wide)
        #expect(MarkdownSelectionTextView.measuringWidth(.infinity) == 400)
        #expect(MarkdownSelectionTextView.measuringWidth(nil) == 400)
    }
}
