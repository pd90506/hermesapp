import Foundation
import Testing

@testable import HermesBridge

@MainActor
@Suite struct MarkdownWireTests {
    private func json(_ parts: [MarkdownPart]) -> [[String: Any]] {
        let data = try! JSONEncoder().encode(parts)
        return try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }

    private func runs(_ part: [String: Any]) -> [[String: Any]] {
        part["prose"] as? [[String: Any]] ?? []
    }

    @Test func proseCodeAndTablesAreSeparateParts() {
        let parts = json(MarkdownPart.parts("""
            # Title

            Some **bold** and *italic* with `code` and a [link](https://example.com).

            ```swift
            let x = 1
            ```

            | A | B |
            |:--|--:|
            | 1 | 2 |
            """, streaming: false))
        #expect(parts.count == 3)
        let prose = runs(parts[0])
        #expect(prose.first?["role"] as? String == "heading")
        #expect(prose.first?["level"] as? Int == 1)
        #expect(prose.contains { $0["text"] as? String == "bold" && $0["bold"] as? Bool == true })
        #expect(prose.contains { $0["text"] as? String == "italic" && $0["italic"] as? Bool == true })
        #expect(prose.contains { $0["text"] as? String == "code" && $0["inlineCode"] as? Bool == true })
        #expect(prose.contains { $0["link"] as? String == "https://example.com" })
        // Off flags are left out.
        #expect(prose.first { $0["text"] as? String == "Some " }?["bold"] == nil)

        let code = parts[1]["code"] as? [String: Any]
        #expect(code?["language"] as? String == "swift")
        #expect(code?["text"] as? String == "let x = 1")
        #expect(code?["isClosed"] as? Bool == true)

        let table = parts[2]["table"] as? [String: Any]
        #expect(table?["alignments"] as? [String] == ["leading", "trailing"])
        let header = table?["header"] as? [[[String: Any]]]
        #expect(header?.first?.first?["text"] as? String == "A")
        let rows = table?["rows"] as? [[[[String: Any]]]]
        #expect(rows?.first?.last?.first?["text"] as? String == "2")
    }

    @Test func listsAndQuotesCarryTheirIndents() {
        let parts = json(MarkdownPart.parts("- one\n- two\n\n> quoted\n\n1. first", streaming: false))
        let prose = runs(parts[0])
        let markers = prose.filter { $0["role"] as? String == "listMarker" }
        #expect(markers.map { $0["text"] as? String } == ["\t•\t", "\t•\t", "\t1.\t"])
        #expect(markers.first?["indents"] as? [String] == ["list"])
        #expect(markers.last?["indents"] as? [String] == ["orderedList"])
        #expect(prose.first { $0["text"] as? String == "quoted" }?["indents"] as? [String] == ["quote"])
        #expect(prose.contains { $0["role"] as? String == "separator" && $0["text"] as? String == "\n" })
        #expect(prose.contains { $0["gap"] as? String == "listItem" })
        #expect(prose.contains { $0["gap"] as? String == "block" })
    }

    @Test func mathShowsItsSource() {
        let prose = runs(json(MarkdownPart.parts("Area $\\pi r^2$ here", streaming: false))[0])
        let math = prose.first { $0["role"] as? String == "math" }
        #expect(math?["text"] as? String == "\\pi r^2")
        #expect(math?["math"] as? String == "\\pi r^2")
        #expect(math?["display"] == nil)
    }

    @Test func anUnclosedFenceStaysOpenWhileStreaming() {
        let parts = json(MarkdownPart.parts("```\nlet", streaming: true))
        let code = parts.last?["code"] as? [String: Any]
        #expect(code?["isClosed"] as? Bool == false)
        #expect(code?["text"] as? String == "let")
    }

    @Test func theCacheReusesFinishedMessagesOnly() {
        let cache = MarkdownCache(limit: 1)
        let first = cache.parts("**a**", streaming: false)
        #expect(cache.parts("**a**", streaming: false) == first)
        _ = cache.parts("b", streaming: false)
        #expect(cache.parts("**a**", streaming: false) == first)
        #expect(cache.parts("**a", streaming: true).isEmpty == false)
    }
}
