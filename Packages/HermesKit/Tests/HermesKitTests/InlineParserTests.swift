import Foundation
import Testing

@testable import HermesKit

@Suite struct InlineParserTests {
    private func inline(_ text: String) -> [MarkdownInline] { InlineParser.parse(text) }
    private func math(_ source: String, display: Bool = false) -> MarkdownInline {
        .math(MathSnippet(source: source, isDisplay: display))
    }

    @Test func emphasisStrongAndStrikethrough() {
        #expect(inline("a *b* __c__ ***d*** ~~e~~") == [
            .text("a "), .emphasis([.text("b")]), .text(" "), .strong([.text("c")]), .text(" "),
            .emphasis([.strong([.text("d")])]), .text(" "), .strikethrough([.text("e")]),
        ])
        #expect(inline("snake_case_name and 2 * 3 * 4 and ~5 min") == [.text("snake_case_name and 2 * 3 * 4 and ~5 min")])
        #expect(inline("**unclosed") == [.text("**unclosed")])
    }

    @Test func emphasisNextToCJKAndPunctuation() {
        #expect(inline("这是**“引用”**文字") == [.text("这是"), .strong([.text("“引用”")]), .text("文字")])
        #expect(inline("中文**粗体**中文") == [.text("中文"), .strong([.text("粗体")]), .text("中文")])
    }

    @Test func codeSpansAreLiteral() {
        #expect(inline("use `a *b* $c$` and `` x`y ``") == [
            .text("use "), .code("a *b* $c$"), .text(" and "), .code("x`y"),
        ])
        #expect(inline("`unclosed") == [.text("`unclosed")])
    }

    @Test func linksAutolinksAndImages() {
        #expect(inline("[the *docs*](https://example.com/a_(b) \"t\") and <https://x.io> or https://y.io/p.") == [
            .link(destination: "https://example.com/a_(b)", content: [.text("the "), .emphasis([.text("docs")])]),
            .text(" and "),
            .link(destination: "https://x.io", content: [.text("https://x.io")]),
            .text(" or "),
            .link(destination: "https://y.io/p", content: [.text("https://y.io/p")]),
            .text("."),
        ])
        #expect(inline("![chart](https://e.com/c.png)") == [.link(destination: "https://e.com/c.png", content: [.text("chart")])])
        #expect(inline("[not a link] [^1]") == [.text("[not a link] [^1]")])
    }

    @Test func escapesEntitiesAndBreaks() {
        #expect(inline(#"\*lit\* a&amp;b &#x4E2D; x<br>y"#) == [.text("*lit* a&b 中 x"), .lineBreak, .text("y")])
        #expect(inline("one  \ntwo\\\nthree") == [.text("one"), .lineBreak, .text("two"), .lineBreak, .text("three")])
        #expect(inline("<div>raw</div>") == [.text("<div>raw</div>")])
    }

    @Test func dollarAmountsAreNotMath() {
        #expect(inline("costs $5 and $10") == [.text("costs $5 and $10")])
        #expect(inline("between $5-$10, or $1,000/$2,000") == [.text("between $5-$10, or $1,000/$2,000")])
        #expect(inline("price: $ 5 $") == [.text("price: $ 5 $")])
        #expect(inline(#"escaped \$x\$"#) == [.text("escaped $x$")])
    }

    @Test func dollarMath() {
        #expect(inline("so $x^2 + y$ holds") == [.text("so "), math("x^2 + y"), .text(" holds")])
        #expect(inline("costs $5 or $x$") == [.text("costs $5 or "), math("x")])
        #expect(inline(#"$\text{\$}5$"#) == [math(#"\text{\$}5"#)])
        #expect(inline("$$E=mc^2$$ inline") == [math("E=mc^2", display: true), .text(" inline")])
    }

    @Test func backslashMath() {
        #expect(inline(#"then \(a_i\) and \[b\]"#) == [.text("then "), math("a_i"), .text(" and "), math("b", display: true)])
        #expect(inline(#"just \( a paren"#) == [.text("just ( a paren")])
    }

    @Test func mathInsideEmphasisAndLinks() {
        #expect(inline("**bold $x$**") == [.strong([.text("bold "), math("x")])])
    }

    @Test func plainTextFlattensMarkup() {
        #expect(inline("a **b** `c` $d$").plainText == "a b c d")
    }
}
