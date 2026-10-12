import AppKit
import HermesKit
import SwiftUI
import Testing

/// Native prose selection and the hosted message layout around components.
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
        let host: NSHostingView<SelectableMarkdownText>
        let view: MarkdownSelectionTextView

        init(host: NSHostingView<SelectableMarkdownText>, view: MarkdownSelectionTextView) {
            self.host = host
            self.view = view
        }

        var layoutManager: NSLayoutManager { view.layoutManager! }
        var storage: NSTextStorage { view.textStorage! }
        var string: NSString { view.string as NSString }

        func update(_ text: String, streaming: Bool = false) {
            host.rootView = SelectableMarkdownText(selection: MarkdownSelection(parsing: text, streaming: streaming),
                                                   source: text, bodySize: 13, isReasoning: false,
                                                   conversationSource: nil)
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
        let host = NSHostingView(rootView: SelectableMarkdownText(
            selection: MarkdownSelection(parsing: text, streaming: streaming), source: text,
            bodySize: 13, isReasoning: reasoning, conversationSource: nil))
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

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for child in view.subviews { result += descendants(type, in: child) }
        return result
    }

    private func fullMessage(_ text: String, width: CGFloat = 320, streaming: Bool = false)
        -> (host: NSHostingView<MarkdownView>, window: NSWindow) {
        let host = NSHostingView(rootView: MarkdownView(text: text, isStreaming: streaming))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        host.frame.size.height = host.fittingSize.height
        let window = NSWindow(contentRect: .testArea(host.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        // Owned by ARC here. With AppKit's default for windows made in code,
        // `close()` would release it a second time and crash at the next
        // autorelease pool drain.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.showInTestArea()
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    @Test func actualMessageHasProseRunsAroundIndependentComponents() throws {
        let text = """
        Before $x$.

        - one
        - two

        ```swift
        let value = 1
        ```

        After.

        | Name | Value |
        |------|-------|
        | a | longer |

        Last.
        """
        let hosted = fullMessage(text)
        defer { hosted.window.close() }
        let runs = descendants(MarkdownSelectionTextView.self, in: hosted.host).filter {
            $0.string.contains("Before") || $0.string == "After." || $0.string == "Last."
        }
        #expect(runs.count == 3)
        guard runs.count == 3 else { return }
        #expect(runs[0].string.contains("Before"))
        #expect(runs[0].string.contains("•"))
        #expect(!runs[0].string.contains("let value"))
        #expect(runs[1].string == "After.")
        #expect(runs[2].string == "Last.")

        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        runs[0].pasteboard = pasteboard
        runs[0].selectAll(nil)
        runs[0].copy(nil)
        #expect(pasteboard.string(forType: .string) == "Before $x$.\n\n- one\n- two")
        #expect(runs[0].selectedRange().length == (runs[0].textStorage?.length ?? 0))

        let cell = try #require(descendants(MarkdownSelectionTextView.self, in: hosted.host)
            .first(where: { $0.string == "longer" }))
        cell.pasteboard = pasteboard
        cell.selectAll(nil)
        cell.copy(nil)
        #expect(pasteboard.string(forType: .string) == "longer")
    }

    @Test func codeAndTableScrollSeparatelyAtFullColumnWidth() throws {
        let code = String(repeating: "veryLongCodeToken", count: 25)
        let cell = String(repeating: "wide ", count: 25)
        let hosted = fullMessage("Intro.\n\n```swift\n\(code)\n```\n\n| Short | Wide |\n|---|---|\n| x | \(cell) |", width: 260)
        defer { hosted.window.close() }
        let prose = try #require(descendants(MarkdownSelectionTextView.self, in: hosted.host)
            .first(where: { $0.string == "Intro." }))
        #expect(prose.frame.width >= 250, "the prose has a trailing gutter")
        let scrolls = descendants(NSScrollView.self, in: hosted.host)
        #expect(scrolls.count >= 2)
        #expect(scrolls.allSatisfy { scroll in
            guard let document = scroll.documentView else { return false }
            return document.frame.width > scroll.contentSize.width + 20
        }, "code and table need their own wider horizontal content")
    }

    /// A table fills the column when it fits (Desktop's `w-full`), and scrolls inside
    /// its own container when it does not; a rounded border, a tinted header row and
    /// rules between rows only.
    @Test func tableFillsTheColumnWithBordersAndATintedHeader() throws {
        let short = fullMessage("| A | B |\n|---|---|\n| x | y |", width: 260)
        defer { short.window.close() }
        let long = fullMessage("| A | Wide |\n|---|---|\n| x | \(String(repeating: "wide ", count: 30)) |", width: 260)
        defer { long.window.close() }
        let shortScroll = try #require(descendants(NSScrollView.self, in: short.host).first)
        let longScroll = try #require(descendants(NSScrollView.self, in: long.host).first)
        let shortWidth = try #require(shortScroll.documentView).frame.width
        let longWidth = try #require(longScroll.documentView).frame.width
        #expect(abs(shortWidth - shortScroll.contentSize.width) <= 2,
                "a short table is \(shortWidth) wide in a \(shortScroll.contentSize.width) column")
        #expect(longWidth > longScroll.contentSize.width + 20, "a wide table does not scroll")

        let rendered = try render(width: 260) {
            MarkdownTableGrid(table: MarkdownTable(alignments: [.none, .none],
                                                  header: [[.text("A")], [.text("B")]],
                                                  rows: [[[.text("x")], [.text("y")]]]))
        }
        // Sample in points, converted with the bitmap's own scale (2x on Retina).
        let scale = CGFloat(rendered.rep.pixelsWide) / rendered.host.bounds.width
        func level(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            brightness(rendered.rep, Int((x * scale).rounded(.down)), Int((y * scale).rounded(.down)))
        }
        func isLine(_ x: CGFloat, _ y: CGFloat) -> Bool { level(x, y) < 0.97 }
        let grid = try #require(box(rendered.rep, width: rendered.host.bounds.width) { x, y in
            brightness(rendered.rep, x, y) < 0.97
        }, "the table draws nothing")
        #expect(grid.width > 240, "the table is \(grid.width) pt wide in a 260 pt column")
        func linesCrossed(from start: CGPoint, to end: CGPoint) -> Int {
            let steps = Int(max(abs(end.x - start.x), abs(end.y - start.y)) * scale)
            var count = 0, inLine = false
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(max(steps, 1))
                let hit = isLine(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t)
                if hit && !inLine { count += 1 }
                inLine = hit
            }
            return count
        }
        // The outer border: each edge is one unbroken line between the rounded corners.
        let inset = MarkdownTableGrid.cornerRadius + 1
        let edges = [(CGPoint(x: grid.minX + inset, y: grid.minY + 0.25), CGPoint(x: grid.maxX - inset, y: grid.minY + 0.25)),
                     (CGPoint(x: grid.minX + inset, y: grid.maxY - 0.25), CGPoint(x: grid.maxX - inset, y: grid.maxY - 0.25)),
                     (CGPoint(x: grid.minX + 0.25, y: grid.minY + inset), CGPoint(x: grid.minX + 0.25, y: grid.maxY - inset)),
                     (CGPoint(x: grid.maxX - 0.25, y: grid.minY + inset), CGPoint(x: grid.maxX - 0.25, y: grid.maxY - inset))]
        for (start, end) in edges {
            #expect(stride(from: 0, through: 1, by: 0.02).allSatisfy {
                isLine(start.x + (end.x - start.x) * $0, start.y + (end.y - start.y) * $0)
            }, "the table border is missing or broken between \(start) and \(end)")
        }
        // The body row's bottom padding (clear of text): only the two borders, no
        // line between the columns.
        let bodyY = grid.maxY - 3
        #expect(linesCrossed(from: CGPoint(x: grid.minX, y: bodyY), to: CGPoint(x: grid.maxX - 0.25, y: bodyY)) == 2,
                "a line between the columns")
        // The header is tinted, the body is not.
        #expect(level(grid.minX + 4, grid.minY + 3) < level(grid.minX + 4, bodyY) - 0.02, "the header row is not tinted")
    }

    @Test func streamingComponentsKeepTheirPlace() throws {
        let hosted = fullMessage("Before.\n\n```swift\nlet a", streaming: true)
        defer { hosted.window.close() }
        let first = try #require(descendants(NSScrollView.self, in: hosted.host).first)
        for source in ["Before.\n\n```swift\nlet a = 1",
                       "Before.\n\n```swift\nlet a = 1\n```",
                       "Before.\n\n```swift\nlet a = 1\n```\n\n| a | b |",
                       "Before.\n\n```swift\nlet a = 1\n```\n\n| a | b |\n|---|---|\n| x | y |"] {
            hosted.host.rootView = MarkdownView(text: source, isStreaming: true)
            hosted.host.frame.size.height = hosted.host.fittingSize.height
            hosted.window.setContentSize(hosted.host.frame.size)
            hosted.host.layoutSubtreeIfNeeded()
            let scrolls = descendants(NSScrollView.self, in: hosted.host)
            #expect(scrolls.count == (source.contains("| a | b |") ? 2 : 1))
            #expect(scrolls.first === first, "the code component was recreated during a delta")
            #expect(descendants(MarkdownSelectionTextView.self, in: hosted.host)
                .filter { $0.string == "Before." }.count == 1)
        }
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

    /// The grid that ships: header cells bold, body cells regular.
    @Test func tableHeaderIsBold() throws {
        let hosted = fullMessage("| Name | Value |\n|---|---|\n| cell1 | cell2 |")
        defer { hosted.window.close() }
        func isBold(_ text: String) throws -> Bool {
            let cell = try #require(descendants(MarkdownSelectionTextView.self, in: hosted.host).first { $0.string == text },
                                    "no grid cell \(text)")
            let font = cell.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            return font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        }
        #expect(try isBold("Name"))
        #expect(try isBold("Value"))
        #expect(try !isBold("cell1"))
        #expect(descendants(NSScrollView.self, in: hosted.host).count == 1, "the table is not the grid component")
    }

    /// Inner lines are one divider, as thick as the outer border, not two cell
    /// borders side by side.
    @Test func tableLinesAreAllOnePoint() throws {
        let rendered = try render(width: 260) {
            MarkdownTableGrid(table: MarkdownTable(alignments: [.none, .none, .none],
                                                  header: [[.text("A")], [.text("B")], [.text("C")]],
                                                  rows: [[[.text("x")], [.text("y")], [.text("z")]],
                                                         [[.text("u")], [.text("v")], [.text("w")]]]))
        }
        let scale = CGFloat(rendered.rep.pixelsWide) / rendered.host.bounds.width
        let grid = try #require(box(rendered.rep, width: rendered.host.bounds.width) { x, y in
            brightness(rendered.rep, x, y) < 0.97
        })
        /// Lengths, in pixels, of the line stretches met along a pixel row or column.
        func runs(along pixels: [(Int, Int)]) -> [Int] {
            var lengths: [Int] = [], current = 0
            for (x, y) in pixels {
                if brightness(rendered.rep, x, y) < 0.97 { current += 1 } else if current > 0 { lengths.append(current); current = 0 }
            }
            if current > 0 { lengths.append(current) }
            return lengths
        }
        // Across the last body row's bottom padding: the two borders. Down the first
        // column: the top border runs into the tinted header and its rule, then the
        // rule between the body rows and the bottom border.
        let row = Int((grid.maxY - 3) * scale)
        let across = runs(along: (Int(grid.minX * scale)...Int(grid.maxX * scale - 1)).map { ($0, row) })
        let column = Int((grid.minX + 4) * scale)
        let down = runs(along: (Int(grid.minY * scale)...Int(grid.maxY * scale - 1)).map { (column, $0) })
        #expect(across.count == 2 && down.count == 3, "across \(across), down \(down)")
        for length in across + down.dropFirst() {
            #expect(length <= Int(scale) + 1, "a line is \(length) px thick; 1 pt is \(Int(scale)) px: \(across) \(down)")
        }
    }

    /// Columns are as wide as the cells render (monospaced inline code, bold),
    /// so a short identifier does not wrap.
    @Test func tableColumnsFitRenderedCells() throws {
        let hosted = fullMessage("| `averyLongIdentifier_name` | **Bold heading text** |\n|---|---|\n| `snake_case_value_42` | [link text here](https://example.com) |",
                                 width: 600)
        defer { hosted.window.close() }
        let cells = descendants(MarkdownSelectionTextView.self, in: hosted.host)
        #expect(cells.count == 4)
        for cell in cells {
            let layoutManager = try #require(cell.layoutManager)
            layoutManager.ensureLayout(for: cell.textContainer!)
            var lines = 0
            layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
                lines += 1
            }
            #expect(lines == 1, "\(cell.string) wraps onto \(lines) lines at width \(cell.frame.width)")
        }
    }

    /// A 50 x 6 table: one layout of each cell's text (the extra measuring layout
    /// manager used to stay attached to every cell, doubling it).
    @Test func bigTableKeepsOneLayoutPerCell() throws {
        let header = "| " + (1...6).map { "Column \($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: "---|", count: 6)
        let rows = (1...50).map { row in "| " + (1...6).map { "r\(row) value \($0)" }.joined(separator: " | ") + " |" }
        let start = Date()
        let hosted = fullMessage(([header, rule] + rows).joined(separator: "\n"), width: 700)
        defer { hosted.window.close() }
        let elapsed = Date().timeIntervalSince(start)
        let cells = descendants(MarkdownSelectionTextView.self, in: hosted.host)
        #expect(cells.count == 51 * 6)
        let managers = cells.reduce(0) { $0 + $1.layoutManagerCount }
        #expect(managers == cells.count, "\(managers) layout managers for \(cells.count) cells")
        // Cells start at their column width, so none lays its text out twice.
        let doubled = cells.filter { $0.offscreenMeasurements > 0 }.count
        #expect(doubled == 0, "\(doubled) cells laid out off screen first")
        print("bigTableKeepsOneLayoutPerCell: built and laid out 306 cells in \(String(format: "%.3f", elapsed)) s")
        #expect(elapsed < 5, "a 50 x 6 table took \(elapsed) s")
    }

    /// A prose run measured at another width keeps a second layout only until it
    /// is placed.
    @Test func placedProseDropsItsMeasuringLayout() throws {
        let hosted = try host(String(repeating: "Words that wrap. ", count: 20), width: 600)
        _ = hosted.view.fittingHeight(width: 300)
        #expect(hosted.view.layoutManagerCount == 2)
        hosted.resize(width: 300)
        #expect(hosted.view.layoutManagerCount == 1)
    }

    /// Right-click in a cell offers the message actions, as in prose and code.
    @Test func tableCellMenuHasMessageActions() throws {
        let text = "Intro.\n\n| Name | Value |\n|---|---|\n| cell1 | cell2 |"
        let host = NSHostingView(rootView: MarkdownView(text: text, isStreaming: false, conversationSource: { "the conversation" }))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: .testArea(host.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let cell = try #require(descendants(MarkdownSelectionTextView.self, in: host).first { $0.string == "cell1" })
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        cell.pasteboard = pasteboard
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: cell.convert(NSPoint(x: 2, y: 2), to: nil),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(cell.menu(for: event))
        let message = try #require(menu.items.first { $0.title == "Copy Message" })
        let conversation = try #require(menu.items.first { $0.title == "Copy Conversation" })
        NSApp.sendAction(try #require(message.action), to: message.target, from: message)
        #expect(pasteboard.string(forType: .string) == text)
        NSApp.sendAction(try #require(conversation.action), to: conversation.target, from: conversation)
        #expect(pasteboard.string(forType: .string) == "the conversation")
    }

    /// The parts of a reply keep 6 pt between them; only the action bar sits flush.
    @Test func replyPartsKeepTheirSpacing() {
        func height(_ view: some View) -> CGFloat { NSHostingView(rootView: view.frame(width: 400)).fittingSize.height }
        let plain = TranscriptItem(id: "a", role: .assistant, text: "Reply.")
        var interrupted = plain
        interrupted.outcome = "interrupted"
        var reasoned = plain
        reasoned.reasoning = "Thought."
        let base = height(AssistantMessageContent(item: plain) {})
        let label = height(Text("Interrupted").font(.caption))
        let disclosure = height(DisclosureGroup("Reasoning") { Text("Thought.") }.font(.caption))
        #expect(abs(height(AssistantMessageContent(item: interrupted) {}) - base - (label + 6)) <= 1)
        #expect(abs(height(AssistantMessageContent(item: reasoned) {}) - base - (disclosure + 6)) <= 1)
        let bar = height(MessageActionBar(isHovering: false, isNewest: false) {})
        let text = height(MarkdownView(text: "Reply.", isStreaming: false))
        #expect(abs(base - (text + bar)) <= 1, "the bar is not flush under the reply")
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

    @Test func actionBarHasStableHeightAndNoGutter() {
        let hidden = NSHostingView(rootView: MessageActionBar(isHovering: false, isNewest: false) {})
        let hovered = NSHostingView(rootView: MessageActionBar(isHovering: true, isNewest: false) {})
        let newest = NSHostingView(rootView: MessageActionBar(isHovering: false, isNewest: true) {})
        #expect(hidden.fittingSize.height == 26)
        #expect(hovered.fittingSize.height == hidden.fittingSize.height)
        #expect(newest.fittingSize.height == hidden.fittingSize.height)
        #expect(MessageActionBar(isHovering: false, isNewest: false, copy: {}).isVisible == false)
        #expect(MessageActionBar(isHovering: true, isNewest: false, copy: {}).isVisible)
        #expect(MessageActionBar(isHovering: false, isNewest: true, copy: {}).isVisible)
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

    @Test func replyActionBarSitsBelowFullWidthText() throws {
        let item = TranscriptItem(id: "a", role: .assistant, text: "Full width reply.")
        let result = try copyButtonAndInk(width: 460) {
            AssistantMessageContent(item: item, isHovering: $0) {}
        }
        let view = try #require(findTextView(in: result.off.host))
        let textFrame = view.convert(view.bounds, to: result.off.host)
        #expect(textFrame.width >= 450, "a trailing gutter narrowed the text")
        #expect(result.button.minY >= textFrame.maxY - 1 || result.button.maxY <= textFrame.minY + 1,
                "action bar overlaps text")
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
