import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing

@testable import HermesKit

/// Regressions from the review of the Markdown/math renderer. Each test names the finding it covers.
/// Serialized: the timing tests keep a thread busy for seconds, and the suites that
/// wait on timers (heartbeats, request timeouts) share the few threads a CI runner has.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MarkdownRegressionTests {
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

    /// How much more time per character `work` takes on `large` than on `small`:
    /// about 1 for linear code, and the size ratio (4 in most tests) for quadratic
    /// code. Tests allow up to 2.5: with four CI-sized test runs competing for one
    /// host, the linear code here measured 1.0 typically and 1.9 at worst.
    ///
    /// A ratio, not an absolute bound: a loaded runner stretches every run by an
    /// unknown factor (CPU time too, through contention), but both sizes alike.
    /// Each size runs five times, interleaved, and the fastest run counts, so a
    /// stall lands in a run that is dropped. Yields between runs to hand the thread
    /// to other tests.
    private func slowdown(_ small: String, _ large: String, _ work: (String) -> Void) async -> Double {
        var best = (small: Double.infinity, large: Double.infinity)
        for _ in 0..<5 {
            best.small = min(best.small, cpuSeconds { work(small) })
            await Task.yield()
            best.large = min(best.large, cpuSeconds { work(large) })
            await Task.yield()
        }
        return (best.large / best.small) / (Double(large.utf8.count) / Double(small.utf8.count))
    }

    /// CPU time of this thread in `body`; `body` is synchronous, so it never leaves the thread.
    private func cpuSeconds(_ body: () -> Void) -> Double {
        func now() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
        }
        let start = now()
        body()
        return now() - start
    }

    private let maxSlowdown = 2.5

    @Test func deeplyNestedQuotesAreCappedNotRecursedForever() {
        let blocks = parse(String(repeating: "> ", count: 16_000) + "x")
        #expect(nestingDepth(blocks) <= blockCap)
    }

    @Test func deeplyNestedListsAreCappedAndFast() async {
        func markers(_ count: Int) -> String { String(repeating: "1. ", count: count) + "x" }
        #expect(nestingDepth(parse(markers(8_000))) <= blockCap)
        #expect(await slowdown(markers(2_000), markers(8_000)) { _ = parse($0) } < maxSlowdown)
        // 4x the lines, each indented further: 16x the text.
        func indented(_ lines: Int) -> String {
            (0..<lines).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
        }
        #expect(nestingDepth(parse(indented(300))) <= blockCap)
        #expect(await slowdown(indented(75), indented(300)) { _ = parse($0) } < maxSlowdown)
    }

    @Test func unmatchedInlineOpenersScanLinearly() async {
        for opener in ["\\(", "\\[", "[", "<", "`", "$", "$$", "![", "*a ", "[a](", "&#", "<http://", "a**", "(http://x"] {
            func text(_ length: Int) -> String { "x " + String(repeating: opener, count: length / opener.count) }
            #expect(await slowdown(text(16_000), text(64_000)) { _ = InlineParser.parse($0) } < maxSlowdown, "opener \(opener)")
        }
        func unbalancedURL(_ count: Int) -> String { "see https://e.com/a" + String(repeating: ")", count: count) }
        #expect(await slowdown(unbalancedURL(8_000), unbalancedURL(32_000)) { _ = InlineParser.parse($0) } < maxSlowdown)
    }

    @Test func deeplyNestedEmphasisIsCapped() async {
        func text(_ count: Int) -> String {
            String(repeating: "*a ", count: count) + "b" + String(repeating: " a*", count: count)
        }
        #expect(await slowdown(text(1_250), text(5_000)) { _ = InlineParser.parse($0) } < maxSlowdown)
        let inlines = InlineParser.parse(text(5_000))
        #expect(inlineDepth(inlines) <= inlineCap)
        #expect(inlines.plainText.filter { $0 == "a" }.count == 10_000)
    }

    @Test func pathologicalLaTeXIsBoundedAndLinear() async {
        // The full-size inputs at `n` = 4_000; `n / 4` for the small run.
        let cases: [(Int) -> String] = [
            { String(repeating: #"\dfrac{"#, count: 2 * $0) + "x" },
            { String(repeating: #"\dfrac{a}{"#, count: $0) + "x" + String(repeating: "}", count: $0) },
            { String(repeating: "{", count: 8 * $0) },
            { String(repeating: #"\begin{aligned}"#, count: $0) },
            { String(repeating: #"\\["#, count: 4 * $0) },
            { String(repeating: #"\operatorname{"#, count: 2 * $0) },
        ]
        for latex in cases {
            #expect(await slowdown(latex(1_000), latex(4_000)) { _ = LaTeXNormalizer.normalize($0) } < maxSlowdown,
                    "\(latex(1).prefix(20))")
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
