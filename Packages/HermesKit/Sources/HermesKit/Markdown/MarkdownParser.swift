import Foundation

/// Block-level Markdown parser for chat replies.
///
/// Supports ATX/setext headings, paragraphs, block quotes, nested ordered and
/// bullet lists (with task checkboxes), fenced code, GFM tables, thematic
/// breaks, and display math (`$$…$$`, `\[…\]`, bare `\begin{align}`-style
/// environments). Deliberate deviations from CommonMark, chosen for model
/// output:
/// - No indented code blocks: indentation inside lists is too often sloppy.
/// - List continuation is lenient: a line indented two or more spaces past the
///   marker belongs to the item even if the item's content starts further right.
/// - A setext underline needs at least three characters, so a `-` that is the
///   start of a streaming list item never turns the paragraph above into a heading.
/// - No raw HTML blocks; HTML is shown as text (except `<br>`, see `InlineParser`).
/// - Quotes and lists nest at most `maxNesting` deep; deeper markers are text.
///
/// Display math needs its closing delimiter. While `streaming`, the closer may
/// still be on its way, so an unclosed block is reported with `isClosed: false`
/// (the app shows its source). In a finished message an opener that is never
/// closed is ordinary text (`\[1] Smith 2020`, `$$$ profit`).
///
/// Also while streaming: an unclosed fence is code with `isClosed: false`, and
/// a trailing pipe row is shown as a table header before its delimiter row
/// arrives, so the layout does not jump from paragraph to table and back.
struct MarkdownParser {
    /// Deepest quote/list nesting parsed as structure; keeps recursion bounded.
    static let maxNesting = 16

    var streaming: Bool

    func parse(_ text: String) -> [MarkdownBlock] {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = unified.split(separator: "\n", omittingEmptySubsequences: false).map { Self.expandTabs($0) }
        return parseBlocks(lines, isTail: true, depth: 0)
    }

    /// The lines of one container (document, quote or list item).
    private final class Lines {
        var items: [String]
        /// `isTail`: the last line is the last line of the whole message.
        let isTail: Bool
        let depth: Int
        /// Per needle: for each line index, the first line at or after it containing the needle.
        private var nextContaining: [String: [Int]] = [:]

        init(_ items: [String], isTail: Bool, depth: Int) {
            self.items = items
            self.isTail = isTail
            self.depth = depth
        }

        var count: Int { items.count }
        subscript(index: Int) -> String { items[index] }

        var canNest: Bool { depth < MarkdownParser.maxNesting }

        /// Whether a line after `index` contains `needle`. Built once per needle,
        /// so many unclosed openers don't each rescan the rest of the message.
        func containsLater(_ needle: String, after index: Int) -> Bool {
            if nextContaining[needle] == nil {
                var table = Array(repeating: items.count, count: items.count + 1)
                for k in stride(from: items.count - 1, through: 0, by: -1) {
                    table[k] = items[k].contains(needle) ? k : table[k + 1]
                }
                nextContaining[needle] = table
            }
            return index + 1 < items.count && nextContaining[needle]![index + 1] < items.count
        }
    }

    private func parseBlocks(_ input: [String], isTail: Bool, depth: Int) -> [MarkdownBlock] {
        let lines = Lines(input, isTail: isTail, depth: depth)
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if Self.isBlank(line) {
                i += 1
            } else if let fence = Fence(opening: line) {
                i = parseFence(fence, lines, from: i, into: &blocks)
            } else if startsDisplayMath(lines, at: i) {
                i = parseDisplayMath(lines, from: i, into: &blocks)
            } else if let heading = Self.atxHeading(line) {
                blocks.append(.heading(level: heading.level, content: InlineParser.parse(heading.text)))
                i += 1
            } else if Self.isThematicBreak(line) {
                blocks.append(.thematicBreak)
                i += 1
            } else if lines.canNest, Self.quoteContent(line) != nil {
                i = parseQuote(lines, from: i, into: &blocks)
            } else if lines.canNest, let marker = ListMarker(line) {
                i = parseList(marker, lines, from: i, into: &blocks)
            } else if let table = tableStart(lines, at: i) {
                i = parseTable(table, lines, into: &blocks)
            } else {
                i = parseParagraph(lines, from: i, into: &blocks)
            }
        }
        return blocks
    }

    // MARK: - Code

    private struct Fence {
        var marker: Character
        var length: Int
        var indent: Int
        var language: String?

        init?(opening line: String) {
            let indent = MarkdownParser.indentation(line)
            guard indent <= 3 else { return nil }
            let rest = line.dropFirst(indent)
            guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
            let length = rest.prefix { $0 == marker }.count
            guard length >= 3 else { return nil }
            let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
            if marker == "`" && info.contains("`") { return nil }
            self.marker = marker
            self.length = length
            self.indent = indent
            let language = info.split(separator: " ").first.map(String.init)
            self.language = language?.isEmpty == false ? language : nil
        }

        func isClosed(by line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= length && trimmed.allSatisfy { $0 == marker }
        }
    }

    private func parseFence(_ fence: Fence, _ lines: Lines, from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var body: [String] = []
        var i = start + 1
        while i < lines.count {
            if fence.isClosed(by: lines[i]) {
                blocks.append(.code(language: fence.language, code: body.joined(separator: "\n"), isClosed: true))
                return i + 1
            }
            body.append(Self.dropIndent(lines[i], upTo: fence.indent))
            i += 1
        }
        // Mid-stream the closing fence has not arrived; a half-typed one is not code.
        if streaming, let last = body.last, !last.isEmpty, last.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.marker }) {
            body.removeLast()
        }
        blocks.append(.code(language: fence.language, code: body.joined(separator: "\n"), isClosed: false))
        return i
    }

    // MARK: - Display math

    static let mathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*",
        "eqnarray", "eqnarray*", "flalign", "flalign*", "alignat", "alignat*", "displaymath",
    ]

    private static func mathDelimiters(_ trimmed: String) -> (open: String, close: String)? {
        if trimmed.hasPrefix("$$") { return ("$$", "$$") }
        if trimmed.hasPrefix(#"\["#) { return (#"\["#, #"\]"#) }
        if trimmed.hasPrefix(#"\begin{"#), let close = trimmed.firstIndex(of: "}") {
            let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<close])
            if mathEnvironments.contains(name) { return ("", #"\end{"# + name + "}") }
        }
        return nil
    }

    /// A line that may start display math. `$$x$$ and more` is a paragraph
    /// with inline display math instead.
    static func isDisplayMathOpener(_ line: String) -> Bool {
        guard indentation(line) <= 3 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let delimiters = mathDelimiters(trimmed) else { return false }
        if delimiters.open.isEmpty { return true }
        let rest = trimmed.dropFirst(delimiters.open.count)
        guard let close = rest.range(of: delimiters.close) else { return true }
        return rest[close.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Display math starts at line `i`: an opener that is closed later, or,
    /// mid-stream, whose closer may still arrive.
    private func startsDisplayMath(_ lines: Lines, at i: Int) -> Bool {
        let line = lines[i]
        guard Self.isDisplayMathOpener(line) else { return false }
        if streaming { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let delimiters = Self.mathDelimiters(trimmed) else { return false }
        if trimmed.dropFirst(delimiters.open.count).contains(delimiters.close) { return true }
        return lines.containsLater(delimiters.close, after: i)
    }

    private func parseDisplayMath(_ lines: Lines, from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        guard let delimiters = Self.mathDelimiters(first) else { return start + 1 }
        // Environments keep their \begin…\end; the normalizer rewrites them.
        var text = String(first.dropFirst(delimiters.open.count))
        var searchFrom = text.startIndex
        var i = start
        while true {
            if let close = text.range(of: delimiters.close, range: searchFrom..<text.endIndex) {
                let source = delimiters.open.isEmpty ? String(text[..<close.upperBound]) : String(text[..<close.lowerBound])
                let rest = text[close.upperBound...].trimmingCharacters(in: .whitespaces)
                blocks.append(.math(MathSnippet(source: source.trimmingCharacters(in: .whitespacesAndNewlines), isDisplay: true)))
                if rest.isEmpty { return i + 1 }
                lines.items[i] = rest  // text after the closing delimiter continues as a new block
                return i
            }
            i += 1
            guard i < lines.count else { break }
            // The closing delimiter cannot straddle a line break, so only search the new line.
            let previousLength = text.utf8.count
            text += "\n" + lines[i]
            searchFrom = text.utf8.index(text.startIndex, offsetBy: previousLength + 1)
        }
        // Only reached mid-stream (`startsDisplayMath` requires a closer otherwise).
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A half-typed closing `$` is not part of the formula.
        if streaming, delimiters.open == "$$", source.hasSuffix("$") { source.removeLast() }
        blocks.append(.math(MathSnippet(source: source.trimmingCharacters(in: .whitespacesAndNewlines), isDisplay: true, isClosed: false)))
        return lines.count
    }

    // MARK: - Headings and breaks

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard indentation(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: `## Title ##`.
        if let hashes = text.lastIndex(where: { $0 != "#" }), text[hashes] == " " {
            text = String(text[..<hashes]).trimmingCharacters(in: .whitespaces)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return (level, text)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indentation(line) <= 3 else { return false }
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func setextLevel(_ line: String) -> Int? {
        guard indentation(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first, first == "=" || first == "-",
              trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    // MARK: - Block quotes

    static func quoteContent(_ line: String) -> String? {
        guard indentation(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard rest.first == ">" else { return nil }
        let content = rest.dropFirst()
        return String(content.first == " " ? content.dropFirst() : content)
    }

    private func parseQuote(_ lines: Lines, from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var inner: [String] = []
        var i = start
        while i < lines.count {
            if let content = Self.quoteContent(lines[i]) {
                inner.append(content)
            } else if let last = inner.last, !Self.isBlank(last), !Self.isBlank(lines[i]), !startsBlock(lines, at: i) {
                inner.append(lines[i])  // lazy paragraph continuation
            } else {
                break
            }
            i += 1
        }
        blocks.append(.blockQuote(parseBlocks(inner, isTail: lines.isTail && i == lines.count, depth: lines.depth + 1)))
        return i
    }

    // MARK: - Lists

    struct ListMarker {
        var ordered: Bool
        var number: Int
        var indent: Int
        var contentIndent: Int
        var content: String

        init?(_ line: String) {
            let indent = MarkdownParser.indentation(line)
            let rest = line.dropFirst(indent)
            guard let first = rest.first else { return nil }
            var width: Int
            if "-+*".contains(first) {
                ordered = false
                number = 0
                width = 1
            } else {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
                let delimiter = rest.dropFirst(digits.count).first
                guard delimiter == "." || delimiter == ")" else { return nil }
                ordered = true
                self.number = number
                width = digits.count + 1
            }
            let after = rest.dropFirst(width)
            let spaces = after.prefix { $0 == " " }.count
            guard after.isEmpty || spaces > 0 else { return nil }
            let text = after.dropFirst(spaces)
            self.indent = indent
            // Content starting 5+ columns out is CommonMark indented code; treat as one space.
            if text.isEmpty || spaces > 4 {
                contentIndent = indent + width + 1
                content = String(text.isEmpty ? "" : after.dropFirst(1))
            } else {
                contentIndent = indent + width + spaces
                content = String(text)
            }
        }

        func continues(_ other: ListMarker) -> Bool { ordered == other.ordered }
    }

    private func parseList(_ first: ListMarker, _ lines: Lines, from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var items: [(marker: ListMarker, lines: [String])] = [(first, [first.content])]
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            let current = items[items.count - 1].marker
            if Self.isBlank(line) {
                items[items.count - 1].lines.append("")
                i += 1
                continue
            }
            let indent = Self.indentation(line)
            if indent >= min(current.contentIndent, current.indent + 2) {
                items[items.count - 1].lines.append(Self.dropIndent(line, upTo: current.contentIndent))
            } else if let marker = ListMarker(line), marker.continues(first), !Self.isThematicBreak(line) {
                items.append((marker, [marker.content]))
            } else if let last = items[items.count - 1].lines.last, !Self.isBlank(last), !startsBlock(lines, at: i) {
                items[items.count - 1].lines.append(line)  // lazy paragraph continuation
            } else {
                break
            }
            i += 1
        }
        // Trailing blank lines belong to whatever follows the list.
        while let last = items[items.count - 1].lines.last, Self.isBlank(last), items[items.count - 1].lines.count > 1 {
            items[items.count - 1].lines.removeLast()
            i -= 1
        }
        let reachesEnd = lines.isTail && i >= lines.count
        let parsed = items.enumerated().map { index, item -> MarkdownList.Item in
            var itemLines = item.lines
            var checkbox: Bool?
            if let box = Self.taskCheckbox(itemLines[0]) {
                checkbox = box.checked
                itemLines[0] = box.rest
            }
            let blocks = parseBlocks(itemLines, isTail: reachesEnd && index == items.count - 1, depth: lines.depth + 1)
            return MarkdownList.Item(checkbox: checkbox, blocks: blocks)
        }
        blocks.append(.list(MarkdownList(start: first.ordered ? first.number : nil, items: parsed)))
        return i
    }

    private static func taskCheckbox(_ content: String) -> (checked: Bool, rest: String)? {
        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where content.hasPrefix(prefix) {
            let rest = content.dropFirst(3)
            guard rest.isEmpty || rest.first == " " else { return nil }
            return (checked, String(rest.dropFirst()))
        }
        return nil
    }

    // MARK: - Tables

    private struct TableStart {
        var header: [String]
        var alignments: [MarkdownTable.Alignment]
        /// Index of the first body row.
        var bodyStart: Int
    }

    private func tableStart(_ lines: Lines, at i: Int) -> TableStart? {
        let line = lines[i]
        guard line.contains("|") else { return nil }
        let header = Self.cells(line)
        if i + 1 < lines.count, let alignments = Self.delimiterRow(lines[i + 1], partial: false), alignments.count == header.count {
            return TableStart(header: header, alignments: alignments, bodyStart: i + 2)
        }
        // Mid-stream: a pipe row at the very end, maybe with a half-written
        // delimiter row under it, is shown as a table header already. The
        // empty line after a just-finished row is where the next one goes.
        guard streaming, lines.isTail, line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return nil }
        let last = lines.count - (lines.count > i + 1 && lines[lines.count - 1].isEmpty ? 2 : 1)
        if i == last {
            return TableStart(header: header, alignments: Array(repeating: .none, count: header.count), bodyStart: i + 1)
        }
        if i + 1 == last, let partial = Self.delimiterRow(lines[i + 1], partial: true) {
            let alignments = (partial + Array(repeating: .none, count: max(0, header.count - partial.count))).prefix(header.count)
            return TableStart(header: header, alignments: Array(alignments), bodyStart: i + 2)
        }
        return nil
    }

    private func parseTable(_ start: TableStart, _ lines: Lines, into blocks: inout [MarkdownBlock]) -> Int {
        let width = start.header.count
        var rows: [[[MarkdownInline]]] = []
        var i = start.bodyStart
        while i < lines.count, !Self.isBlank(lines[i]), lines[i].contains("|"), !startsBlock(lines, at: i) {
            var cells = Self.cells(lines[i])
            if cells.count < width { cells += Array(repeating: "", count: width - cells.count) }
            rows.append(cells.prefix(width).map(InlineParser.parse))
            i += 1
        }
        blocks.append(.table(MarkdownTable(alignments: start.alignments, header: start.header.map(InlineParser.parse), rows: rows)))
        return i
    }

    /// Splits a table row on unescaped pipes outside code spans and inline
    /// math. As in GFM, `\|` is a literal pipe, also inside code spans; inside
    /// math it stays `\|` (the LaTeX double bar).
    static func cells(_ line: String) -> [String] {
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        var look = Lookahead(chars)
        var cells: [String] = []
        var cell = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "|" {
                cell.append("|")
                i += 2
            } else if c == "$" || (c == "\\" && i + 1 < chars.count && "([".contains(chars[i + 1])), let span = look.inlineMath(at: i) {
                cell += String(chars[i..<span.end])
                i = span.end
            } else if c == "\\", i + 1 < chars.count {
                cell.append(c)
                cell.append(chars[i + 1])
                i += 2
            } else if c == "`" {
                let run = look.backtickRun(at: i)
                if let close = look.closingBacktickRun(length: run, after: i) {
                    cell += String(chars[i..<(close + run)]).replacingOccurrences(of: #"\|"#, with: "|")
                    i = close + run
                } else {
                    cell += String(repeating: "`", count: run)  // unmatched: literal, splitting continues
                    i += run
                }
            } else if c == "|" {
                cells.append(cell)
                cell = ""
                i += 1
            } else {
                cell.append(c)
                i += 1
            }
        }
        cells.append(cell)
        if chars.first == "|" { cells.removeFirst() }
        if chars.count > 1, chars.last == "|", cells.count > 1, cells.last?.isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func delimiterRow(_ line: String, partial: Bool) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        // A bare `---` is a thematic break or setext underline, not a one-column table.
        if !partial, !trimmed.contains("|") { return nil }
        var cells = cells(trimmed)
        if partial, cells.last?.isEmpty == true { cells.removeLast() }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells {
            var dashes = Substring(cell)
            let leading = dashes.hasPrefix(":")
            if leading { dashes = dashes.dropFirst() }
            let trailing = dashes.hasSuffix(":")
            if trailing { dashes = dashes.dropLast() }
            guard dashes.allSatisfy({ $0 == "-" }), partial || !dashes.isEmpty else { return nil }
            switch (leading, trailing) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.leading)
            case (false, true): alignments.append(.trailing)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    // MARK: - Paragraphs

    private func parseParagraph(_ lines: Lines, from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var text: [String] = [lines[start].trimmingCharacters(in: .whitespaces)]
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            if Self.isBlank(line) { break }
            if let level = Self.setextLevel(line) {
                blocks.append(.heading(level: level, content: InlineParser.parse(text.joined(separator: "\n"))))
                return i + 1
            }
            if startsBlock(lines, at: i) || tableStart(lines, at: i) != nil { break }
            text.append(String(line.drop { $0 == " " }))
            i += 1
        }
        blocks.append(.paragraph(InlineParser.parse(text.joined(separator: "\n"))))
        return i
    }

    /// Whether line `i` opens a block that ends a paragraph or lazy continuation.
    private func startsBlock(_ lines: Lines, at i: Int) -> Bool {
        let line = lines[i]
        if Fence(opening: line) != nil || startsDisplayMath(lines, at: i) || Self.atxHeading(line) != nil
            || Self.isThematicBreak(line) {
            return true
        }
        guard lines.canNest else { return false }
        if Self.quoteContent(line) != nil { return true }
        guard let marker = ListMarker(line), marker.indent <= 3 else { return false }
        // As in CommonMark, only a non-empty item (ordered: starting at 1) interrupts a paragraph.
        return !marker.content.isEmpty && (!marker.ordered || marker.number == 1)
    }

    // MARK: - Lines

    static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func dropIndent(_ line: String, upTo count: Int) -> String {
        String(line.dropFirst(min(count, indentation(line))))
    }

    /// Leading tabs become four spaces so indentation is measured in columns.
    static func expandTabs(_ line: Substring) -> String {
        guard line.first == "\t" || line.first == " " else { return String(line) }
        var column = 0
        var rest = line[...]
        while let c = rest.first, c == " " || c == "\t" {
            column += c == "\t" ? 4 - column % 4 : 1
            rest = rest.dropFirst()
        }
        return String(repeating: " ", count: column) + rest
    }
}
