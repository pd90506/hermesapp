import Foundation
import Testing

@testable import HermesKit

@Suite struct MarkdownParserTests {
    private func parse(_ text: String, streaming: Bool = false) -> [MarkdownBlock] {
        MarkdownDocument(parsing: text, streaming: streaming).blocks
    }

    @Test func headingsParagraphsAndBreaks() {
        let blocks = parse("# Title #\n\nFirst line\nsecond line\n\n---\n\nSetext\n===\n\n#hashtag")
        #expect(blocks == [
            .heading(level: 1, content: [.text("Title")]),
            .paragraph([.text("First line"), .lineBreak, .text("second line")]),
            .thematicBreak,
            .heading(level: 1, content: [.text("Setext")]),
            .paragraph([.text("#hashtag")]),
        ])
    }

    @Test func nestedListsWithLenientIndentation() {
        let blocks = parse("1. one\n  - sub a\n  - sub b\n2. two\n\n- [x] done\n- [ ] todo")
        let sub = MarkdownBlock.list(MarkdownList(start: nil, items: [
            .init(blocks: [.paragraph([.text("sub a")])]),
            .init(blocks: [.paragraph([.text("sub b")])]),
        ]))
        #expect(blocks == [
            .list(MarkdownList(start: 1, items: [
                .init(blocks: [.paragraph([.text("one")]), sub]),
                .init(blocks: [.paragraph([.text("two")])]),
            ])),
            .list(MarkdownList(start: nil, items: [
                .init(checkbox: true, blocks: [.paragraph([.text("done")])]),
                .init(checkbox: false, blocks: [.paragraph([.text("todo")])]),
            ])),
        ])
    }

    @Test func listInterruptsParagraphAndKeepsMultiParagraphItems() {
        let blocks = parse("Steps:\n- a\n\n  more about a\n- b\n\nAfter")
        #expect(blocks == [
            .paragraph([.text("Steps:")]),
            .list(MarkdownList(start: nil, items: [
                .init(blocks: [.paragraph([.text("a")]), .paragraph([.text("more about a")])]),
                .init(blocks: [.paragraph([.text("b")])]),
            ])),
            .paragraph([.text("After")]),
        ])
    }

    @Test func orderedListOnlyInterruptsParagraphAtOne() {
        #expect(parse("In\n2019. it rained") == [.paragraph([.text("In"), .lineBreak, .text("2019. it rained")])])
    }

    @Test func blockQuoteWithLazyContinuation() {
        let blocks = parse("> quoted **bold**\nlazy\n> - item\n\nout")
        #expect(blocks == [
            .blockQuote([
                .paragraph([.text("quoted "), .strong([.text("bold")]), .lineBreak, .text("lazy")]),
                .list(MarkdownList(start: nil, items: [.init(blocks: [.paragraph([.text("item")])])])),
            ]),
            .paragraph([.text("out")]),
        ])
    }

    @Test func fencedCodeKeepsContentVerbatim() {
        let blocks = parse("```swift\nlet x = \"*not* $math$\"\n\n  indented\n```\nafter")
        #expect(blocks == [
            .code(language: "swift", code: "let x = \"*not* $math$\"\n\n  indented", isClosed: true),
            .paragraph([.text("after")]),
        ])
        #expect(parse("~~~~\n```\n~~~~") == [.code(language: nil, code: "```", isClosed: true)])
    }

    @Test func codeFenceInsideListItem() {
        let blocks = parse("- run:\n  ```sh\n  ls -la\n  ```")
        #expect(blocks == [.list(MarkdownList(start: nil, items: [
            .init(blocks: [.paragraph([.text("run:")]), .code(language: "sh", code: "ls -la", isClosed: true)]),
        ]))])
    }

    @Test func gfmTable() throws {
        let blocks = parse("| Name | Score | Note |\n|:-----|------:|:----:|\n| a | `x|y` | **ok** |\n| b \\| c | 2 |\n\nafter")
        let table = MarkdownTable(
            alignments: [.leading, .trailing, .center],
            header: [[.text("Name")], [.text("Score")], [.text("Note")]],
            rows: [
                [[.text("a")], [.code("x|y")], [.strong([.text("ok")])]],
                [[.text("b | c")], [.text("2")], []],
            ]
        )
        #expect(blocks == [.table(table), .paragraph([.text("after")])])
    }

    @Test func tableInterruptsParagraphAndPipesAloneAreText() {
        let blocks = parse("Here:\na | b\n--|--\n1 | 2")
        #expect(blocks.count == 2)
        guard case .table(let table) = blocks.last else { Issue.record("expected a table"); return }
        #expect(table.header == [[.text("a")], [.text("b")]])
        #expect(table.rows == [[[.text("1")], [.text("2")]]])
        #expect(parse("a | b\nno delimiter") == [.paragraph([.text("a | b"), .lineBreak, .text("no delimiter")])])
    }

    @Test func displayMathDelimiters() {
        let blocks = parse("Before\n$$\n\\frac{a}{b}\n$$\n\\[ x^2 \\]\n$$ y $$\n\\begin{align}\na &= b\n\\end{align}\nafter")
        #expect(blocks == [
            .paragraph([.text("Before")]),
            .math(MathSnippet(source: #"\frac{a}{b}"#, isDisplay: true)),
            .math(MathSnippet(source: "x^2", isDisplay: true)),
            .math(MathSnippet(source: "y", isDisplay: true)),
            .math(MathSnippet(source: "\\begin{align}\na &= b\n\\end{align}", isDisplay: true)),
            .paragraph([.text("after")]),
        ])
    }

    @Test func textAfterClosingMathContinues() {
        #expect(parse("$$\nx\n$$ where x is real") == [
            .math(MathSnippet(source: "x", isDisplay: true)),
            .paragraph([.text("where x is real")]),
        ])
    }

    @Test func inlineDisplayMathOnALineWithTextStaysInParagraph() {
        #expect(parse("$$a$$ and $$b$$") == [.paragraph([
            .math(MathSnippet(source: "a", isDisplay: true)), .text(" and "), .math(MathSnippet(source: "b", isDisplay: true)),
        ])])
    }

    @Test func crlfAndTabs() {
        #expect(parse("- a\r\n\t- b\r\n") == [.list(MarkdownList(start: nil, items: [
            .init(blocks: [.paragraph([.text("a")]), .list(MarkdownList(start: nil, items: [.init(blocks: [.paragraph([.text("b")])])]))]),
        ]))])
    }

    // MARK: - Streaming

    @Test func unclosedFenceAndMathWhileStreaming() {
        #expect(parse("```py\nprint(1)\n``", streaming: true) == [.code(language: "py", code: "print(1)", isClosed: false)])
        #expect(parse("$$\n\\sum_i x_i\n$", streaming: true) == [
            .math(MathSnippet(source: #"\sum_i x_i"#, isDisplay: true, isClosed: false)),
        ])
        // Finished but never closed: the text is kept as written.
        #expect(parse("```\ncode\n``") == [.code(language: nil, code: "code\n``", isClosed: false)])
    }

    @Test func provisionalTableHeaderWhileStreaming() {
        let header = MarkdownTable(alignments: [.none, .none], header: [[.text("a")], [.text("b")]], rows: [])
        #expect(parse("Intro\n\n| a | b |", streaming: true) == [.paragraph([.text("Intro")]), .table(header)])
        var partial = header
        partial.alignments = [.leading, .none]
        #expect(parse("| a | b |\n|:--|-", streaming: true) == [.table(partial)])
        // Not streaming: a lone pipe row is just text.
        #expect(parse("| a | b |") == [.paragraph([.text("| a | b |")])])
    }

    @Test func halfWrittenRowsPadToHeaderWidth() {
        let blocks = parse("| a | b |\n|---|---|\n| 1", streaming: true)
        #expect(blocks == [.table(MarkdownTable(
            alignments: [.none, .none], header: [[.text("a")], [.text("b")]], rows: [[[.text("1")], []]]
        ))])
    }

    /// While text streams in, every block except the last keeps its kind:
    /// finished blocks never flip between paragraph, table, code or math.
    @Test func streamingPrefixesNeverChangeFinishedBlocks() {
        let message = """
        # Report

        Prices: costs $5 and $10, and $x^2$ is math.

        | Item | Cost |
        |------|-----:|
        | A | $5 |
        | B | $\\frac{1}{2}$ |

        ```swift
        let s = "$$"
        ```

        $$
        \\begin{aligned} a &= b \\\\ c &= d \\end{aligned}
        $$

        1. first
           - nested *em*
        2. second

        > quote with \\(x\\)

        Done **bold** ~~gone~~.
        """
        var previous: [MarkdownBlock] = []
        for end in message.indices + [message.endIndex] {
            let blocks = parse(String(message[..<end]), streaming: true)
            for (index, block) in previous.dropLast().enumerated() {
                #expect(index < blocks.count && block.kind == blocks[index].kind, "prefix ending \(message.distance(from: message.startIndex, to: end))")
            }
            previous = blocks
        }
        #expect(parse(message, streaming: true) == parse(message))
        #expect(previous.map(\.kind) == ["heading", "paragraph", "table", "code", "math", "list", "blockQuote", "paragraph"])
    }
}

extension MarkdownBlock {
    var kind: String {
        switch self {
        case .paragraph: "paragraph"
        case .heading: "heading"
        case .blockQuote: "blockQuote"
        case .list: "list"
        case .code: "code"
        case .math: "math"
        case .table: "table"
        case .thematicBreak: "thematicBreak"
        }
    }
}
