import Testing

@testable import HermesKit

@Suite struct CodeHighlighterTests {
    private func kinds(_ code: String, _ language: String?) -> [String: CodeHighlighter.Kind] {
        var map: [String: CodeHighlighter.Kind] = [:]
        for span in CodeHighlighter.spans(code, language: language) where span.kind != .plain {
            map[span.text] = span.kind
        }
        return map
    }

    @Test(arguments: [
        ("python", "def greet(name: str) -> str:\n    # say hi\n    return f\"Hello, {name}!\"\n\nprint(greet('world'), 42, None)"),
        ("swift", "let x = 1..<5 // range\n/* block */ struct A { func f() {} }"),
        ("json", "{\"a\": [1, true, \"s\"]}"),
        (nil, "plain text, no language: 'quote' 3.14"),
        ("js", "const s = `multi\nline`; /* unclosed"),
    ] as [(String?, String)])
    func theSpansAreTheCodeExactly(language: String?, code: String) {
        #expect(CodeHighlighter.spans(code, language: language).map(\.text).joined() == code)
    }

    @Test func pythonKeywordsStringsCommentsNumbersAndCalls() {
        let k = kinds("def greet(name):\n    # say hi\n    return \"Hello\" + str(42) if name else None", "python")
        #expect(k["def"] == .keyword)
        #expect(k["return"] == .keyword)
        #expect(k["# say hi"] == .comment)
        #expect(k["\"Hello\""] == .string)
        #expect(k["42"] == .number)
        #expect(k["greet"] == .function)
        #expect(k["str"] == .function)
        #expect(k["None"] == .literal)
    }

    @Test func swiftTypesAndBlockComments() {
        let k = kinds("/* note */\nstruct Point { let x: Double }", "swift")
        #expect(k["/* note */"] == .comment)
        #expect(k["struct"] == .keyword)
        #expect(k["Point"] == .type)
        #expect(k["Double"] == .type)
    }

    @Test func jsonKeysAreNotValues() {
        let k = kinds("{\"name\": \"Talaria\", \"ok\": true}", "json")
        #expect(k["\"name\""] == .type)
        #expect(k["\"Talaria\""] == .string)
        #expect(k["true"] == .literal)
    }

    @Test func shellVariablesAndComments() {
        let k = kinds("export PATH=$HOME/bin # add bin\necho \"$PATH\"", "bash")
        #expect(k["export"] == .keyword)
        #expect(k["$HOME"] == .type)
        #expect(k["# add bin"] == .comment)
    }

    @Test func anUnclosedStringOrCommentRunsToTheEndWhileStreaming() {
        let spans = CodeHighlighter.spans("x = 1 /* still", language: "c")
        #expect(spans.last == CodeHighlighter.Span("/* still", .comment))
        let line = CodeHighlighter.spans("s = \"open\nnext", language: "python")
        #expect(line.contains(CodeHighlighter.Span("\"open", .string)))
    }

    @Test func sqlKeywordsIgnoreCase() {
        let k = kinds("SELECT name FROM users -- all", "sql")
        #expect(k["SELECT"] == .keyword)
        #expect(k["FROM"] == .keyword)
        #expect(k["-- all"] == .comment)
    }

    @Test func hugeCodeStaysPlain() {
        let code = String(repeating: "x", count: CodeHighlighter.maxLength + 1)
        #expect(CodeHighlighter.spans(code, language: "swift") == [CodeHighlighter.Span(code, .plain)])
    }
}
