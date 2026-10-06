import Foundation

/// Inline Markdown: emphasis, strong, `~~strike~~`, code spans, links,
/// autolinks, `<br>`, a few HTML entities, and inline math.
///
/// Math delimiters are `$…$`, `$$…$$` (display style), `\(…\)` and `\[…\]`.
/// A single `$` follows Pandoc's rule so prices don't turn into math: the
/// opener must be followed by a non-space, the closer preceded by a non-space
/// and not followed by a digit. On top of that (see `Lookahead.inlineMath`):
/// - the first unescaped `$` after an opener decides; if it cannot close, the
///   opener is literal ("costs $5 and $10" stays text, "$5 or $x$" yields `x`);
/// - math never spans a backtick, so code spans win (`` a $b `c$` d ``);
/// - `$` + digit followed by CJK text is a price (`成本是$5，而$x$`);
/// - `$` + an all-caps name followed by `/` or `:` is a shell variable (`$HOME/$USER`).
///
/// Every line break inside a paragraph is kept as a line break (CommonMark
/// would fold soft breaks into spaces), which suits chat text and CJK.
///
/// Input is model-controlled, so every forward search is memoized
/// (`Lookahead`) and emphasis nesting is capped at `maxNesting`: parsing is
/// roughly linear and the result tree stays shallow enough to render.
enum InlineParser {
    /// Deeper emphasis keeps its delimiters as text.
    static let maxNesting = 32

    static func parse(_ text: String) -> [MarkdownInline] {
        var scanner = Scanner(chars: Array(text), allowsLinks: true)
        return scanner.run().inlines
    }

    private enum Node {
        case inline(MarkdownInline, depth: Int)
        case delimiter(Character, count: Int, canOpen: Bool, canClose: Bool)
    }

    private struct Scanner {
        let chars: [Character]
        let allowsLinks: Bool
        var look: Lookahead
        var nodes: [Node] = []
        var buffer = ""

        init(chars: [Character], allowsLinks: Bool) {
            self.chars = chars
            self.allowsLinks = allowsLinks
            self.look = Lookahead(chars)
        }

        mutating func run() -> (inlines: [MarkdownInline], depth: Int) {
            var i = 0
            while i < chars.count {
                i = step(at: i)
            }
            flush()
            return InlineParser.resolveEmphasis(nodes)
        }

        private mutating func flush() {
            guard !buffer.isEmpty else { return }
            nodes.append(.inline(.text(buffer), depth: 0))
            buffer = ""
        }

        private mutating func emit(_ inline: MarkdownInline, depth: Int = 0) {
            flush()
            nodes.append(.inline(inline, depth: depth))
        }

        /// Consumes one construct starting at `i`; returns the next index.
        private mutating func step(at i: Int) -> Int {
            let c = chars[i]
            switch c {
            case "\\":
                return backslash(at: i)
            case "`":
                return codeSpan(at: i)
            case "$":
                return dollar(at: i)
            case "*", "_", "~":
                return delimiterRun(at: i)
            case "[":
                if allowsLinks, let end = link(at: i, isImage: false) { return end }
            case "!":
                if allowsLinks, i + 1 < chars.count, chars[i + 1] == "[", let end = link(at: i + 1, isImage: true) { return end }
            case "<":
                if let end = angleBracket(at: i) { return end }
            case "&":
                if let end = entity(at: i) { return end }
            case "\n":
                // Trailing spaces and a trailing backslash only mark hard breaks in CommonMark.
                while buffer.last == " " { buffer.removeLast() }
                emit(.lineBreak)
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                return j
            case "h", "H":
                if allowsLinks, let end = bareURL(at: i) { return end }
            default:
                break
            }
            buffer.append(c)
            return i + 1
        }

        // MARK: Escapes and math

        private mutating func backslash(at i: Int) -> Int {
            guard i + 1 < chars.count else {
                buffer.append("\\")
                return i + 1
            }
            let next = chars[i + 1]
            if next == "(" || next == "[", let end = math(at: i) { return end }
            if next == "\n" {
                return i + 1  // hard-break backslash; the newline itself emits the break
            }
            if next.isASCII, next.isPunctuation || next.isSymbol {
                buffer.append(next)
                return i + 2
            }
            buffer.append("\\")
            return i + 1
        }

        private mutating func dollar(at i: Int) -> Int {
            if let end = math(at: i) { return end }
            let isDouble = i + 1 < chars.count && chars[i + 1] == "$"
            buffer += isDouble ? "$$" : "$"
            return i + (isDouble ? 2 : 1)
        }

        private mutating func math(at i: Int) -> Int? {
            guard let span = look.inlineMath(at: i) else { return nil }
            let source = String(chars[span.content]).trimmingCharacters(in: .whitespacesAndNewlines)
            emit(.math(MathSnippet(source: source, isDisplay: span.display)))
            return span.end
        }

        // MARK: Code

        private mutating func codeSpan(at i: Int) -> Int {
            let run = look.backtickRun(at: i)
            guard let close = look.closingBacktickRun(length: run, after: i) else {
                buffer += String(repeating: "`", count: run)
                return i + run
            }
            var code = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
            if code.count >= 2, code.first == " ", code.last == " ", !code.allSatisfy({ $0 == " " }) {
                code = String(code.dropFirst().dropLast())
            }
            emit(.code(code))
            return close + run
        }

        // MARK: Emphasis

        private mutating func delimiterRun(at i: Int) -> Int {
            let c = chars[i]
            var run = 1
            while i + run < chars.count, chars[i + run] == c { run += 1 }
            if c == "~" && run != 2 {
                buffer += String(repeating: "~", count: run)  // `~5 min` is not strikethrough
                return i + run
            }
            // Math next to the run counts as a word character, so `**$x$**text` is bold.
            var before: Character = i > 0 ? chars[i - 1] : " "
            if buffer.isEmpty, case .inline(.math, _)? = nodes.last { before = "a" }
            var after: Character = i + run < chars.count ? chars[i + run] : " "
            if "$\\".contains(after), look.inlineMath(at: i + run) != nil { after = "a" }
            // CommonMark flanking rules, relaxed so that CJK text next to
            // punctuation (e.g. **“引用”**文字) still gets emphasis.
            let left = !after.isWhitespace && (!after.isMarkdownPunctuation || before.isWhitespace || before.isMarkdownPunctuation || !before.isASCII)
            let right = !before.isWhitespace && (!before.isMarkdownPunctuation || after.isWhitespace || after.isMarkdownPunctuation || !after.isASCII)
            let canOpen: Bool
            let canClose: Bool
            if c == "_" {
                canOpen = left && (!right || before.isMarkdownPunctuation)
                canClose = right && (!left || after.isMarkdownPunctuation)
            } else {
                canOpen = left
                canClose = right
            }
            flush()
            nodes.append(.delimiter(c, count: run, canOpen: canOpen, canClose: canClose))
            return i + run
        }

        // MARK: Links

        /// `[text](destination "title")` starting at the `[` at `i`.
        private mutating func link(at i: Int, isImage: Bool) -> Int? {
            guard let labelEnd = look.closingBracket(of: i), labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else { return nil }
            guard let (destination, end) = destination(from: labelEnd + 2) else { return nil }
            var inner = Scanner(chars: Array(chars[(i + 1)..<labelEnd]), allowsLinks: false)
            var (content, depth) = inner.run()
            if isImage, content.isEmpty { content = [.text(destination)] }
            emit(.link(destination: destination, content: content), depth: depth + 1)
            return end
        }

        /// Destinations longer than this are not links; bounds the scan on junk input.
        private static let maxDestination = 2048

        private mutating func destination(from start: Int) -> (String, Int)? {
            var j = start
            while j < chars.count, chars[j] == " " { j += 1 }
            var destination = ""
            if j < chars.count, chars[j] == "<" {
                guard let close = look.next(.angle, from: j + 1, where: { [chars] in chars[$0] == ">" || chars[$0] == "\n" }),
                      chars[close] == ">", close - j <= Self.maxDestination else { return nil }
                destination = String(chars[(j + 1)..<close])
                j = close + 1
            } else {
                // Up to the `)` closing the link's `(`, or the first space before it.
                guard let close = look.closingBracket(of: start - 1) else { return nil }
                let space = look.next(.whitespace, from: j, where: { [chars] in chars[$0].isWhitespace }) ?? chars.count
                let end = min(close, space)
                guard end - j <= Self.maxDestination else { return nil }
                destination = String(chars[j..<end])
                j = end
            }
            while j < chars.count, chars[j] == " " { j += 1 }
            // Optional title, ignored.
            if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
                let quote = chars[j]
                guard let close = look.next(.character(quote), from: j + 1, where: { [chars] in chars[$0] == quote }) else { return nil }
                j = close + 1
                while j < chars.count, chars[j] == " " { j += 1 }
            }
            guard j < chars.count, chars[j] == ")" else { return nil }
            return (destination, j + 1)
        }

        /// `<https://…>` autolinks and `<br>` line breaks; other HTML stays text.
        private mutating func angleBracket(at i: Int) -> Int? {
            guard let close = look.next(.angle, from: i + 1, where: { [chars] in chars[$0] == ">" || chars[$0] == "\n" }),
                  chars[close] == ">", close - i <= Self.maxDestination else { return nil }
            let inside = String(chars[(i + 1)..<close])
            if ["br", "br/", "br /"].contains(inside.lowercased()) {
                emit(.lineBreak)
                return close + 1
            }
            if allowsLinks, inside.contains("://") || inside.hasPrefix("mailto:"), !inside.contains(where: \.isWhitespace) {
                emit(.link(destination: inside, content: [.text(inside)]))
                return close + 1
            }
            return nil
        }

        /// GFM extended autolink: a bare `http(s)://` URL after a word boundary.
        private mutating func bareURL(at i: Int) -> Int? {
            if i > 0, !(chars[i - 1].isWhitespace || "(*_~\"'".contains(chars[i - 1]) || !chars[i - 1].isASCII) { return nil }
            let lower = String(chars[i..<min(chars.count, i + 8)]).lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
            var end = i
            var opens = 0
            var closes = 0
            while end < chars.count, !chars[end].isWhitespace, chars[end] != "<", chars[end].isASCII {
                if chars[end] == "(" { opens += 1 }
                if chars[end] == ")" { closes += 1 }
                end += 1
            }
            // Trailing punctuation belongs to the sentence; so does an unbalanced `)`.
            while end > i {
                let last = chars[end - 1]
                if ".,:;!?'\"*_~".contains(last) {
                    end -= 1
                } else if last == ")", opens < closes {
                    closes -= 1
                    end -= 1
                } else {
                    break
                }
            }
            guard end - i > (lower.hasPrefix("https") ? 8 : 7) else { return nil }
            let text = String(chars[i..<end])
            emit(.link(destination: text, content: [.text(text)]))
            return end
        }

        // MARK: Entities

        private static let entities: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        ]

        private mutating func entity(at i: Int) -> Int? {
            let limit = min(chars.count, i + 10)
            guard let semicolon = chars[i..<limit].firstIndex(of: ";") else { return nil }
            let name = String(chars[(i + 1)..<semicolon])
            var code: UInt32?
            if let named = Self.entities[name] {
                buffer += named
                return semicolon + 1
            } else if name.hasPrefix("#x") || name.hasPrefix("#X") {
                code = UInt32(name.dropFirst(2), radix: 16)
            } else if name.hasPrefix("#") {
                code = UInt32(name.dropFirst())
            }
            guard let code else { return nil }
            // As in CommonMark, NUL and invalid code points decode to U+FFFD.
            let scalar = code == 0 ? nil : Unicode.Scalar(code)
            buffer.append(Character(scalar ?? "\u{FFFD}"))
            return semicolon + 1
        }
    }

    // MARK: - Emphasis resolution

    /// CommonMark's delimiter matching (without the "multiple of 3" rule) on a
    /// stack, with per-character lower bounds so failed opener searches are
    /// never repeated. Runs in O(n × maxNesting).
    private static func resolveEmphasis(_ input: [Node]) -> (inlines: [MarkdownInline], depth: Int) {
        var stack: [Node] = []
        var bottom: [Character: Int] = [:]
        for node in input {
            guard case .delimiter(let c, var count, let closerCanOpen, true) = node else {
                stack.append(node)
                continue
            }
            while count > 0 {
                var opener: Int?
                var k = stack.count - 1
                while k >= (bottom[c] ?? 0) {
                    if case .delimiter(c, let openCount, true, _) = stack[k], openCount > 0 {
                        opener = k
                        break
                    }
                    k -= 1
                }
                guard let opener, case .delimiter(_, let openCount, let openerCanOpen, let openerCanClose) = stack[opener] else {
                    bottom[c] = stack.count  // nothing at or below here can open `c`
                    break
                }
                let used = c == "~" ? 2 : (openCount >= 2 && count >= 2 ? 2 : 1)
                let inner = Array(stack[(opener + 1)...])
                stack.removeSubrange((opener + 1)...)
                stack[opener] = .delimiter(c, count: openCount - used, canOpen: openerCanOpen, canClose: openerCanClose)
                count -= used
                let (children, depth) = finish(inner)
                if depth < maxNesting {
                    let wrapped: MarkdownInline = c == "~" ? .strikethrough(children) : used == 2 ? .strong(children) : .emphasis(children)
                    stack.append(.inline(wrapped, depth: depth + 1))
                } else {
                    // Too deep to render safely: keep the delimiters as text.
                    let marks = MarkdownInline.text(String(repeating: c, count: used))
                    stack.append(.inline(marks, depth: 0))
                    stack += children.map { .inline($0, depth: depth) }
                    stack.append(.inline(marks, depth: 0))
                }
                for key in bottom.keys where bottom[key, default: 0] > opener + 1 { bottom[key] = opener + 1 }
            }
            if count > 0 { stack.append(.delimiter(c, count: count, canOpen: closerCanOpen, canClose: true)) }
        }
        return finish(stack)
    }

    /// Unmatched delimiters become text; adjacent text merges.
    private static func finish(_ nodes: [Node]) -> (inlines: [MarkdownInline], depth: Int) {
        var result: [MarkdownInline] = []
        var text = ""
        var depth = 0
        for node in nodes {
            switch node {
            case .inline(.text(let value), _):
                text += value
            case .inline(let inline, let nodeDepth):
                if !text.isEmpty { result.append(.text(text)) }
                text = ""
                result.append(inline)
                depth = max(depth, nodeDepth)
            case .delimiter(let c, let count, _, _):
                text += String(repeating: c, count: count)
            }
        }
        if !text.isEmpty { result.append(.text(text)) }
        return (result, depth)
    }
}

/// Forward searches over one run of text, memoized so repeated unmatched
/// openers (`[[[[`, `\(\(\(`, ```` ``` ````…) never rescan the same text.
///
/// A search for a key from `start` finds the first matching index at or after
/// `start`. Remembering the last query per key answers any later query from a
/// start inside the already-scanned range without scanning again; parsers
/// only move forward, so each key scans the text about once in total.
struct Lookahead {
    enum Key: Hashable {
        case dollar, doubleDollar, closeParen, closeBracket, angle, whitespace
        case character(Character)
    }

    let chars: [Character]
    private var memo: [Key: (from: Int, found: Int?)] = [:]
    private var brackets: [Int: Int]?
    private var backticks: [Int: [Int]]?

    init(_ chars: [Character]) {
        self.chars = chars
    }

    /// First index at or after `start` where `match` holds. With
    /// `skipEscapes`, a backslash and the character after it are skipped.
    mutating func next(_ key: Key, from start: Int, skipEscapes: Bool = false, where match: (Int) -> Bool) -> Int? {
        if let previous = memo[key], start >= previous.from {
            guard let found = previous.found else { return nil }
            if start <= found { return found }
        }
        var j = start
        while j < chars.count {
            if skipEscapes, chars[j] == "\\" {
                j += 2
                continue
            }
            if match(j) {
                memo[key] = (start, j)
                return j
            }
            j += 1
        }
        memo[key] = (start, nil)
        return nil
    }

    // MARK: Math

    /// An inline math span starting at `i` (`$`, `$$`, `\(` or `\[`): the
    /// content range, the index after the closer, and whether it is display style.
    mutating func inlineMath(at i: Int) -> (content: Range<Int>, end: Int, display: Bool)? {
        guard i + 1 < chars.count else { return nil }
        let span: (content: Range<Int>, end: Int, display: Bool)
        switch (chars[i], chars[i + 1]) {
        case ("$", "$"):
            guard let close = next(.doubleDollar, from: i + 2, skipEscapes: true, where: { [chars] j in
                chars[j] == "`" || (chars[j] == "$" && j + 1 < chars.count && chars[j + 1] == "$")
            }), chars[close] == "$" else { return nil }
            span = ((i + 2)..<close, close + 2, true)
        case ("$", _):
            guard let close = closingDollar(after: i) else { return nil }
            span = ((i + 1)..<close, close + 1, false)
        case ("\\", "("), ("\\", "["):
            let closer: Character = chars[i + 1] == "(" ? ")" : "]"
            guard let close = next(closer == ")" ? .closeParen : .closeBracket, from: i + 2, where: { [chars] j in
                chars[j] == "`" || (chars[j] == "\\" && j + 1 < chars.count && chars[j + 1] == closer)
            }), chars[close] == "\\" else { return nil }
            span = ((i + 2)..<close, close + 2, closer == "]")
        default:
            return nil
        }
        guard chars[span.content].contains(where: { !$0.isWhitespace }) else { return nil }
        return span
    }

    private mutating func closingDollar(after opener: Int) -> Int? {
        let first = chars[opener + 1]
        guard !first.isWhitespace, !isShellVariable(at: opener + 1) else { return nil }
        guard let close = next(.dollar, from: opener + 1, skipEscapes: true, where: { [chars] in chars[$0] == "$" || chars[$0] == "`" }),
              chars[close] == "$" else { return nil }
        let followedByDigit = close + 1 < chars.count && chars[close + 1].isNumber
        if chars[close - 1].isWhitespace || followedByDigit { return nil }
        // `成本是$5，而$x$`: a price followed by CJK prose, not math.
        if first.isNumber, chars[(opener + 1)..<close].contains(where: \.isCJK) { return nil }
        return close
    }

    /// `$HOME/…`, `$PATH:…`: two or more capitals (then capitals, digits or
    /// `_`) directly followed by `/` or `:`.
    private func isShellVariable(at start: Int) -> Bool {
        var j = start
        while j < chars.count, chars[j].isASCII, chars[j].isUppercase { j += 1 }
        guard j - start >= 2 else { return false }
        while j < chars.count, chars[j].isASCII, chars[j].isUppercase || chars[j].isNumber || chars[j] == "_" { j += 1 }
        return j < chars.count && (chars[j] == "/" || chars[j] == ":")
    }

    // MARK: Brackets and code spans

    /// The `]` or `)` matching the `[` or `(` at `i`, ignoring escaped ones.
    mutating func closingBracket(of i: Int) -> Int? {
        if brackets == nil {
            var matches: [Int: Int] = [:]
            var squares: [Int] = []
            var parens: [Int] = []
            var j = 0
            while j < chars.count {
                switch chars[j] {
                case "\\": j += 1
                case "[": squares.append(j)
                case "]": if let start = squares.popLast() { matches[start] = j }
                case "(": parens.append(j)
                case ")": if let start = parens.popLast() { matches[start] = j }
                default: break
                }
                j += 1
            }
            brackets = matches
        }
        return brackets?[i]
    }

    /// Length of the backtick run starting at `i`.
    func backtickRun(at i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j] == "`" { j += 1 }
        return j - i
    }

    /// Start of the next backtick run of exactly `length` after `i`: the
    /// closer of a code span opened at `i` (CommonMark).
    mutating func closingBacktickRun(length: Int, after i: Int) -> Int? {
        if backticks == nil {
            var runs: [Int: [Int]] = [:]
            var j = 0
            while j < chars.count {
                guard chars[j] == "`" else {
                    j += 1
                    continue
                }
                let run = backtickRun(at: j)
                runs[run, default: []].append(j)
                j += run
            }
            backticks = runs
        }
        guard let starts = backticks?[length] else { return nil }
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= i { low = mid + 1 } else { high = mid }
        }
        return low < starts.count ? starts[low] : nil
    }
}

extension Character {
    /// Unicode punctuation or symbol, as CommonMark's flanking rules use it.
    var isMarkdownPunctuation: Bool { isPunctuation || isSymbol }

    /// CJK ideographs, kana, Hangul, and CJK/fullwidth punctuation.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF: true
            default: false
            }
        }
    }
}
