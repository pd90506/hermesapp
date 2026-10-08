import Testing
@testable import HermesKit

@Suite struct MarkdownPresentationTests {
    @Test func proseRemainsOneSelectableRunBetweenComponents() {
        let source = """
        First $x$.

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
        let parts = MarkdownPresentation(parsing: source).parts
        #expect(parts.map(\.id) == [0, 2, 3, 4, 5])
        guard parts.count == 5 else { Issue.record("expected five parts"); return }
        guard case .prose(let first) = parts[0].content,
              case .code(let language, let code, let closed) = parts[1].content,
              case .prose(let middle) = parts[2].content,
              case .table(let table) = parts[3].content,
              case .prose(let last) = parts[4].content else {
            Issue.record("unexpected presentation parts")
            return
        }
        #expect(first.plainText == "First $x$.\n\n- one\n- two")
        #expect(language == "swift" && code == "let value = 1" && closed)
        #expect(middle.plainText == "After.")
        #expect(table.rows[0][1].plainText == "longer")
        #expect(last.plainText == "Last.")
    }

    @Test func streamingKeepsAnOpenFenceAndPartialTableAsComponents() {
        let prefixes = ["Before.\n\n```swift\n", "Before.\n\n```swift\nlet a", "Before.\n\n```swift\nlet a\n```",
                        "Before.\n\n```swift\nlet a\n```\n\n| a | b |", "Before.\n\n```swift\nlet a\n```\n\n| a | b |\n|:--|-",
                        "Before.\n\n```swift\nlet a\n```\n\n| a | b |\n|:--|---|\n| x | y |"]
        for (index, prefix) in prefixes.enumerated() {
            let parts = MarkdownPresentation(parsing: prefix, streaming: true).parts
            #expect(parts.count == (index < 3 ? 2 : 3))
            guard parts.count == (index < 3 ? 2 : 3) else { continue }
            guard case .prose(let prose) = parts[0].content,
                  case .code(_, let code, let closed) = parts[1].content else {
                Issue.record("fence moved into prose at prefix \(index)")
                return
            }
            #expect(prose.plainText == "Before.")
            #expect(code == (index == 0 ? "" : "let a"))
            #expect(closed == (index >= 2))
            if index >= 3 {
                guard case .table = parts[2].content else { Issue.record("partial table left grid"); return }
            }
        }
    }

    @Test func messageCopyKeepsOriginalMarkdownBytes() {
        let source = "Before  \n\n```swift\nlet x = 1  \n```\n\n| a | b |\n|---|---|\n| x | y |\n"
        let item = TranscriptItem(id: "answer", role: .assistant, text: source)
        #expect(ConversationMarkdown.messageSource(for: item) == source)
        #expect(ConversationMarkdown.export([item]) == "## Assistant\n\n" + source)
    }

    // MARK: Parts against the whole message

    /// What a part shows, in the whole-message selection's spelling.
    private func text(of part: MarkdownPresentation.Part) -> String {
        switch part.content {
        case .prose(let selection): selection.plainText
        case .code(_, let text, _): text
        case .table(let table): MarkdownSelection(document: MarkdownDocument(blocks: [.table(table)])).plainText
        }
    }

    private func kind(of part: MarkdownPresentation.Part) -> String {
        switch part.content {
        case .prose: "prose"
        case .code: "code"
        case .table: "table"
        }
    }

    private static let mixed = """
    Intro with $x$ and `code`.

    - one
    - two

    ```swift
    let a = 1
    let b = 2
    ```

    Between.

    | Name | Value |
    |------|-------|
    | a | **b** |
    | c | d |

    > quoted

    ```
    tail code
    ```

    Last.
    """

    /// At every streaming prefix, the parts hold exactly the blocks of the whole
    /// message, in order: nothing duplicated or lost at a part boundary.
    @Test func partsAddUpToTheMessageAtEveryPrefix() {
        let source = Self.mixed
        for end in source.indices.dropFirst() + [source.endIndex] {
            let prefix = String(source[..<end])
            let parts = MarkdownPresentation(parsing: prefix, streaming: true).parts
            let whole = MarkdownSelection(parsing: prefix, streaming: true).plainText
            #expect(parts.map(text(of:)).joined(separator: "\n\n") == whole, "prefix \(prefix.count): \(prefix.debugDescription)")
            #expect(parts.map(\.id) == parts.map(\.id).sorted() && Set(parts.map(\.id)).count == parts.count)
            #expect(!zip(parts, parts.dropFirst()).contains { kind(of: $0) == "prose" && kind(of: $1) == "prose" },
                    "two prose runs side by side at prefix \(prefix.count)")
        }
        let final = MarkdownPresentation(parsing: source).parts
        #expect(final.map(kind(of:)) == ["prose", "code", "prose", "table", "prose", "code", "prose"])
    }

    /// Streaming only changes the tail: each part but the last keeps its id, kind
    /// and (except for the last one) content in the next prefix.
    @Test func partIdsAreStableAcrossPrefixes() {
        let source = Self.mixed
        var previous: [MarkdownPresentation.Part] = []
        for end in source.indices.dropFirst() + [source.endIndex] {
            let parts = MarkdownPresentation(parsing: String(source[..<end]), streaming: true).parts
            for old in previous.dropLast() {
                let new = parts.first { $0.id == old.id }
                #expect(new != nil, "part \(old.id) vanished at prefix \(source.distance(from: source.startIndex, to: end))")
                #expect(new.map(kind(of:)) == kind(of: old), "part \(old.id) changed kind")
            }
            previous = parts
        }
    }

    @Test func twoBackticksThenAFence() {
        let parts = MarkdownPresentation(parsing: "``\n\n```swift\nlet a\n```").parts
        #expect(parts.map(kind(of:)) == ["prose", "code"])
        guard parts.count == 2 else { return }
        #expect(text(of: parts[0]) == "``")
        #expect(text(of: parts[1]) == "let a")
    }

    /// A fence inside a list item stays in the prose run (the documented fallback).
    @Test func fenceInsideAListItemStaysInProse() {
        let source = "- item\n\n  ```\n  nested code\n  ```\n- next"
        let parts = MarkdownPresentation(parsing: source).parts
        #expect(parts.map(kind(of:)) == ["prose"])
        #expect(parts.first.map(text(of:))?.contains("nested code") == true)
        #expect(parts.map(text(of:)).joined(separator: "\n\n") == MarkdownSelection(parsing: source).plainText)
    }

    /// While streaming, a lone `|` line shows as a one-row table; once the next
    /// line shows it isn't one, it is prose, keeping its id, and no text is lost.
    @Test func pipeLineThatIsNotATable() {
        let streaming = MarkdownPresentation(parsing: "Intro.\n\n| not a table", streaming: true).parts
        #expect(streaming.map(kind(of:)) == ["prose", "table"])
        let settled = "Intro.\n\n| not a table\nbut prose after all"
        for parts in [MarkdownPresentation(parsing: settled, streaming: true).parts, MarkdownPresentation(parsing: settled).parts] {
            #expect(!parts.contains { kind(of: $0) == "table" })
            #expect(parts.map(text(of:)).joined(separator: "\n\n").contains("| not a table"))
            #expect(parts.map(text(of:)).joined(separator: "\n\n") == MarkdownSelection(parsing: settled).plainText)
        }
    }

    @Test func newestMessageIsTheLastUserOrAssistantRow() {
        let user = TranscriptItem(id: "u", role: .user, text: "q")
        let reply = TranscriptItem(id: "a", role: .assistant, text: "r")
        let tool = TranscriptItem(id: "t", role: .tool, text: "")
        let system = TranscriptItem(id: "s", role: .system, text: "note")
        #expect(ConversationMarkdown.newestMessageID(in: [user, reply, tool, system]) == "a")
        #expect(ConversationMarkdown.newestMessageID(in: [reply, user, tool]) == "u")
        #expect(ConversationMarkdown.newestMessageID(in: [tool]) == nil)
        #expect(ConversationMarkdown.newestMessageID(in: []) == nil)
    }
}
