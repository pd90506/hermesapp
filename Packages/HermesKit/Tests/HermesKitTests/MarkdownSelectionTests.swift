import Foundation
import Testing
@testable import HermesKit

@Suite struct MarkdownSelectionTests {
    /// Tags the runs as the app renderer does; every formula renders as one attachment.
    private func rendered(_ selection: MarkdownSelection) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for index in selection.runs.indices {
            result.append(NSAttributedString(string: selection.runs[index].text,
                                             attributes: selection.copyAttributes(forRunAt: index)))
        }
        return result
    }

    private func copyAll(_ selection: MarkdownSelection) -> String {
        let text = rendered(selection)
        return MarkdownSelection.copyText(from: text, range: NSRange(location: 0, length: text.length))
    }

    @Test func blockOrderAndAttributedRuns() {
        let source = """
        # Title

        First **bold** paragraph with $x^2$.

        Second paragraph.

        1. one
        2. two

        ```swift
        let x = 1
        ```

        | A | B |
        |---|---|
        | 1 | 2 |

        $$y = x^2$$
        """
        let selection = MarkdownSelection(parsing: source)
        let expected = "Title\n\nFirst bold paragraph with $x^2$.\n\nSecond paragraph.\n\n1. one\n2. two\n\nlet x = 1\n\nA\tB\n1\t2\n\n$$y = x^2$$"
        #expect(selection.plainText == expected)
        #expect(copyAll(selection) == expected)
        #expect(selection.runs.contains { $0.text == "bold" && $0.bold })
        #expect(selection.runs.contains { $0.text == "let x = 1" && $0.role == .code })
        #expect(selection.runs.filter { $0.math != nil }.map(\.copyText) == ["$x^2$", "$$y = x^2$$"])
    }

    @Test func blocksAreOneLineBreakOnScreenAndABlankLineWhenCopied() {
        let selection = MarkdownSelection(parsing: "One.\n\nTwo.")
        #expect(rendered(selection).string == "One.\nTwo.")
        #expect(copyAll(selection) == "One.\n\nTwo.")
        #expect(selection.runs.last?.gap == .block)
    }

    @Test func partialSelectionAcrossAttachmentsAndCode() throws {
        let selection = MarkdownSelection(parsing: "Before $x$ after.\n\n```\ncode\n```\n\nDone")
        let text = rendered(selection)
        let display = text.string as NSString
        let start = display.range(of: "Before").location
        let end = display.range(of: "Done").location + 4
        #expect(MarkdownSelection.copyText(from: text, range: NSRange(location: start, length: end - start))
                == "Before $x$ after.\n\ncode\n\nDone")
    }

    @Test func listsShowMarkersAndCopyMarkdown() throws {
        let selection = MarkdownSelection(parsing: "- one\n  - nested\n- [x] done\n- [ ] todo\n\n3. three")
        let shown = rendered(selection).string
        #expect(shown.contains("\t•\tone"))
        #expect(shown.contains("\t◦\tnested"))
        #expect(shown.contains("\t☑\tdone"))
        #expect(shown.contains("\t☐\ttodo"))
        #expect(shown.contains("\t3.\tthree"))
        #expect(!shown.contains("- "))
        #expect(copyAll(selection) == "- one\n  - nested\n- [x] done\n- [ ] todo\n\n3. three")

        let nested = try #require(selection.runs.first { $0.text == "nested" })
        #expect(nested.indents == [.list(ordered: false), .list(ordered: false)])
        let todo = try #require(selection.runs.firstIndex { $0.text == "\t☐\t" })
        #expect(selection.runs[todo].role == .listMarker)
        #expect(selection.runs[todo].gap == .listItem)
    }

    @Test func selectingPartOfAMarkerCopiesTheWholeMarker() {
        let selection = MarkdownSelection(parsing: "- one\n- two")
        let text = rendered(selection)
        let marker = (text.string as NSString).range(of: "•\ttwo")
        #expect(MarkdownSelection.copyText(from: text, range: NSRange(location: marker.location, length: 5)) == "- two")
    }

    @Test func adjacentUnitsWithEqualCopyTextStaySeparate() {
        let text = NSMutableAttributedString()
        for index in 0..<2 {
            text.append(NSAttributedString(string: "\u{FFFC}", attributes: [
                MarkdownSelection.runIndexAttribute: index, MarkdownSelection.copyTextAttribute: "$x$",
            ]))
        }
        #expect(MarkdownSelection.copyText(from: text, range: NSRange(location: 0, length: 2)) == "$x$$x$")
    }

    /// The text system splits a run where it substitutes a fallback font.
    @Test func aUnitSplitByOtherAttributesIsCopiedOnce() {
        let selection = MarkdownSelection(parsing: "- [ ] todo")
        let text = NSMutableAttributedString(attributedString: rendered(selection))
        let box = (text.string as NSString).range(of: "☐")
        text.addAttribute(NSAttributedString.Key("Font"), value: "fallback", range: box)
        #expect(MarkdownSelection.copyText(from: text, range: NSRange(location: 0, length: text.length)) == "- [ ] todo")
    }

    @Test func quotesAreIndentedNotPrefixed() {
        let selection = MarkdownSelection(parsing: "> quoted\n> more\n\nafter")
        #expect(!rendered(selection).string.contains(">"))
        #expect(selection.runs.first { $0.text.contains("quoted") }?.isQuoted == true)
        #expect(selection.runs.last?.isQuoted == false)
    }

    @Test func codeBlockHasALanguageLineThatIsNotCopied() {
        let selection = MarkdownSelection(parsing: "Intro\n\n```swift\nlet x = 1\n```")
        #expect(rendered(selection).string == "Intro\nswift\nlet x = 1")
        #expect(copyAll(selection) == "Intro\n\nlet x = 1")
        #expect(selection.runs.contains { $0.role == .codeLanguage && $0.text == "swift\n" })
    }

    @Test func unclosedDisplayMathCopiesItsOpeningDelimiterOnly() throws {
        let selection = MarkdownSelection(parsing: "$$\\frac{a}{b}", streaming: true)
        let math = try #require(selection.runs.first { $0.math != nil })
        #expect(math.math?.isClosed == false)
        #expect(math.copyText == "$$\\frac{a}{b}")
    }

    @Test func conversationUsesLoadedRowsAndOriginalSource() {
        var user = TranscriptItem(id: "1", role: .user, text: "**what I typed**")
        user.reasoning = "hidden"
        var assistant = TranscriptItem(id: "2", role: .assistant, text: "# Answer")
        assistant.reasoning = "hidden reasoning"
        #expect(ConversationMarkdown.messageSource(for: user) == "**what I typed**")
        #expect(ConversationMarkdown.export([user, assistant]) == "## User\n\n**what I typed**\n\n## Assistant\n\n# Answer")
        var tool = TranscriptItem(id: "3", role: .tool, text: "")
        tool.toolName = "search"
        tool.detail = "query"
        #expect(ConversationMarkdown.messageSource(for: tool) == "search\nquery")
    }
}
