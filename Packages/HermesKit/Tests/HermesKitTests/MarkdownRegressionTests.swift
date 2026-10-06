import Foundation
import Testing

@testable import HermesKit

/// Regressions from the review of the Markdown/math renderer. Each test names the finding it covers.
@Suite struct MarkdownRegressionTests {
    private func parse(_ text: String, streaming: Bool = false) -> [MarkdownBlock] {
        MarkdownDocument(parsing: text, streaming: streaming).blocks
    }

    private func math(_ source: String, display: Bool = false) -> MarkdownInline {
        .math(MathSnippet(source: source, isDisplay: display))
    }

    // MARK: 1. Unclosed display math in a finished message

    @Test func unclosedBracketOpenerIsTextOnceFinished() {
        #expect(parse("Refs:\n\\[1] Smith 2020\n\nMore text here.\n\n## Heading") == [
            .paragraph([.text("Refs:"), .lineBreak, .text("[1] Smith 2020")]),
            .paragraph([.text("More text here.")]),
            .heading(level: 2, content: [.text("Heading")]),
        ])
    }

    @Test func unclosedDollarOpenerIsTextOnceFinished() {
        #expect(parse("$$$ profit\n\nNext para") == [.paragraph([.text("$$$ profit")]), .paragraph([.text("Next para")])])
        #expect(parse("\\begin{align}\na &= b\n\nafter") == [
            .paragraph([.text("\\begin{align}"), .lineBreak, .text("a &= b")]),
            .paragraph([.text("after")]),
        ])
    }

    @Test func unclosedOpenerStillPendingWhileStreaming() {
        #expect(parse("Refs:\n\\[1] Smith", streaming: true) == [
            .paragraph([.text("Refs:")]),
            .math(MathSnippet(source: "1] Smith", isDisplay: true, isClosed: false)),
        ])
    }

    // MARK: 2. Unbounded nesting and quadratic paths

    /// The caps `MarkdownParser.maxNesting` / `InlineParser.maxNesting` must stay within.
    private let blockCap = 16
    private let inlineCap = 32

    private func nestingDepth(_ blocks: [MarkdownBlock]) -> Int {
        blocks.map { block in
            switch block {
            case .blockQuote(let inner): 1 + nestingDepth(inner)
            case .list(let list): 1 + (list.items.map { nestingDepth($0.blocks) }.max() ?? 0)
            default: 0
            }
        }.max() ?? 0
    }

    private func inlineDepth(_ inlines: [MarkdownInline]) -> Int {
        inlines.map { inline in
            switch inline {
            case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, let c): 1 + inlineDepth(c)
            default: 0
            }
        }.max() ?? 0
    }

    /// Wall time of `body`; generous bounds keep this stable on slow CI while
    /// still failing for the quadratic versions (seconds to minutes at these sizes).
    private func seconds(_ body: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure(body)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test func deeplyNestedQuotesAreCappedNotRecursedForever() {
        let blocks = parse(String(repeating: "> ", count: 16_000) + "x")
        #expect(nestingDepth(blocks) <= blockCap)
    }

    @Test func deeplyNestedListsAreCappedAndFast() {
        var blocks: [MarkdownBlock] = []
        let time = seconds { blocks = parse(String(repeating: "1. ", count: 8_000) + "x") }
        #expect(nestingDepth(blocks) <= blockCap)
        #expect(time < 1.0)
        let indented = (0..<300).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
        #expect(seconds { blocks = parse(indented) } < 2.0)
        #expect(nestingDepth(blocks) <= blockCap)
    }

    @Test func unmatchedInlineOpenersScanLinearly() {
        for opener in ["\\(", "\\[", "[", "<", "`", "$", "$$", "![", "*a ", "[a](", "&#", "<http://", "a**", "(http://x"] {
            let text = "x " + String(repeating: opener, count: 64_000 / opener.count)
            #expect(seconds { _ = InlineParser.parse(text) } < 1.0, "opener \(opener)")
        }
        let unbalancedURL = "see https://e.com/a" + String(repeating: ")", count: 32_000)
        #expect(seconds { _ = InlineParser.parse(unbalancedURL) } < 1.0)
    }

    @Test func deeplyNestedEmphasisIsCapped() {
        let text = String(repeating: "*a ", count: 5_000) + "b" + String(repeating: " a*", count: 5_000)
        var inlines: [MarkdownInline] = []
        #expect(seconds { inlines = InlineParser.parse(text) } < 1.0)
        #expect(inlineDepth(inlines) <= inlineCap)
        #expect(inlines.plainText.filter { $0 == "a" }.count == 10_000)
    }

    @Test func pathologicalLaTeXIsBoundedAndLinear() {
        let cases = [
            String(repeating: #"\dfrac{"#, count: 8_000) + "x",
            String(repeating: #"\dfrac{a}{"#, count: 4_000) + "x" + String(repeating: "}", count: 4_000),
            String(repeating: "{", count: 32_000),
            String(repeating: #"\begin{aligned}"#, count: 4_000),
            String(repeating: #"\\["#, count: 16_000),
            String(repeating: #"\operatorname{"#, count: 8_000),
        ]
        for latex in cases {
            #expect(seconds { _ = LaTeXNormalizer.normalize(latex) } < 1.0, "\(latex.prefix(20))")
        }
    }

    // MARK: 3. Streamed tables must not flash table → paragraph → table

    @Test func headerRowNewlineKeepsTheTable() {
        let header = MarkdownTable(alignments: [.none, .none], header: [[.text("a")], [.text("b")]], rows: [])
        #expect(parse("| a | b |\n", streaming: true) == [.table(header)])
    }

    /// For every prefix of a streamed message, no block position goes back to
    /// a kind it already left (e.g. table → paragraph → table).
    @Test func streamedBlockKindsNeverFlipBack() {
        let message = """
        Intro paragraph.

        | Item | Cost |
        |------|-----:|
        | A | $5 |
        | B | $|x|$ |

        - one
        - two

        $$
        x^2
        $$

        > quote

        ```
        code
        ```

        # Heading
        Last line.
        """
        var history: [[String]] = []
        for end in message.indices + [message.endIndex] {
            let kinds = parse(String(message[..<end]), streaming: true).map(\.kind)
            for (index, kind) in kinds.enumerated() {
                if index == history.count { history.append([]) }
                if history[index].last != kind {
                    #expect(!history[index].contains(kind), "block \(index) flipped back to \(kind) at \(message.distance(from: message.startIndex, to: end))")
                    history[index].append(kind)
                }
            }
        }
    }

    // MARK: 4. Pipes inside math in table cells

    @Test func pipesInsideCellMathDoNotSplit() {
        let blocks = parse("| f | value |\n|---|---|\n| abs | $|x|$ |\n| norm | $\\|v\\|$ |\n| paren | \\(|y|\\) |")
        guard case .table(let table) = blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows == [
            [[.text("abs")], [math("|x|")]],
            [[.text("norm")], [math(#"\|v\|"#)]],
            [[.text("paren")], [math("|y|")]],
        ])
    }

    // MARK: 5. Normalizer must not fuse commands

    @Test func droppedCommandsDoNotFuseNeighbours() {
        #expect(LaTeXNormalizer.normalize(#"\alpha\label{eq}b"#) == #"\alpha b"#)
        #expect(LaTeXNormalizer.normalize(#"\pm\phantom{x}a"#) == #"\pm a"#)
        #expect(LaTeXNormalizer.normalize(#"\alpha\nonumber x"#) == #"\alpha x"#)
        #expect(LaTeXNormalizer.normalize(#"\beta\begin{equation}x\end{equation}"#) == #"\beta x"#)
        // Escaped backslash before letters is a row break, not a command: no space needed.
        #expect(LaTeXNormalizer.normalize(#"a\\\label{x}b"#) == #"a\\b"#)
    }

    @Test func mediumSpaceIsRewritten() {
        #expect(LaTeXNormalizer.normalize(#"a\:b\>c"#) == #"a\;b\;c"#)
    }

    // MARK: Nits

    @Test func emphasisAroundMath() {
        #expect(InlineParser.parse("**$x$**text") == [.strong([math("x")]), .text("text")])
        #expect(InlineParser.parse("text**$x$**") == [.text("text"), .strong([math("x")])])
    }

    @Test func dollarHeuristicWithoutWhitespace() {
        #expect(InlineParser.parse("成本是$5，而$x$代表数量") == [.text("成本是$5，而"), math("x"), .text("代表数量")])
        #expect(InlineParser.parse("$HOME/$USER and $PATH:$HOME") == [.text("$HOME/$USER and $PATH:$HOME")])
        #expect(InlineParser.parse("a $b `c$` d") == [.text("a $b "), .code("c$"), .text(" d")])
        // Still math: subscripts and geometry.
        #expect(InlineParser.parse("$F_1/F_2$") == [math("F_1/F_2")])
    }

    @Test func invalidNumericEntitiesBecomeReplacementCharacter() {
        #expect(InlineParser.parse("a&#0;b&#xD800;c") == [.text("a\u{FFFD}b\u{FFFD}c")])
    }

    @Test func unmatchedBacktickInTableHeaderKeepsTheTable() {
        let blocks = parse("| `a | b |\n|---|---|\n| 1 | 2 |")
        guard case .table(let table) = blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.header == [[.text("`a")], [.text("b")]])
        #expect(table.rows == [[[.text("1")], [.text("2")]]])
    }

    @Test func escapedPipeInsideTableCodeSpanFollowsGFM() {
        guard case .table(let table) = parse("| a |\n|---|\n| `x\\|y` |").first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows == [[[.code("x|y")]]])
    }
}
