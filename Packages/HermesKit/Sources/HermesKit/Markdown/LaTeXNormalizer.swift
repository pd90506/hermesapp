import Foundation

/// Rewrites model-written LaTeX into the subset SwiftMath 1.7.3 parses.
///
/// The apps render math natively with SwiftMath, whose parser rejects a number
/// of common amsmath commands and environments. Where a faithful equivalent
/// exists it is substituted here (often a Unicode symbol, which the parser
/// accepts and Latin Modern Math has a glyph for); a few constructs with no
/// equivalent get a close approximation (`\boxed` drops the box, `\underbrace`
/// becomes an underline). Anything else is left alone so the renderer fails
/// and the app shows the original source. The tables below were checked
/// against SwiftMath 1.7.3's `MTMathListBuilder` on the Mac.
///
/// Input is model-controlled: brace, bracket and environment matching is
/// precomputed in one pass, and recursion into arguments and environments
/// stops at `maxNesting` (deeper text is passed through unchanged), so
/// normalizing is linear and cannot exhaust the stack.
public enum LaTeXNormalizer {
    static let maxNesting = 32

    public static func normalize(_ source: String) -> String {
        let rewriter = Rewriter(Array(source.trimmingCharacters(in: .whitespacesAndNewlines)))
        return rewriter.rewrite(0..<rewriter.chars.count, depth: 0)
    }

    // MARK: - Tables

    /// Argument-free commands replaced by a supported command or symbol.
    static let symbols: [String: String] = [
        "dots": #"\ldots"#, "dotsc": #"\ldots"#, "dotso": #"\ldots"#,
        "dotsb": #"\cdots"#, "dotsm": #"\cdots"#, "dotsi": #"\cdots"#,
        "implies": #"\Longrightarrow"#, "impliedby": #"\Longleftarrow"#,
        "iint": #"\int\!\!\int"#, "iiint": #"\int\!\!\int\!\!\int"#, "oiint": "∯",
        "varnothing": #"\emptyset"#, "smallsetminus": #"\setminus"#,
        "leqslant": #"\leq"#, "geqslant": #"\geq"#, "leqq": "≦", "geqq": "≧",
        "lt": "<", "gt": ">",
        "lvert": "|", "rvert": "|", "lVert": #"\|"#, "rVert": #"\|"#,
        "Box": #"\square"#, "blacksquare": "■", "lozenge": "◊", "checkmark": "✓",
        "nexists": "∄", "complement": "∁", "therefore": "∴", "because": "∵",
        "hookrightarrow": "↪", "hookleftarrow": "↩", "longmapsto": "⟼",
        "rightleftharpoons": "⇌", "leftrightharpoons": "⇋",
        "rightleftarrows": "⇄", "leftrightarrows": "⇆",
        "twoheadrightarrow": "↠", "rightsquigarrow": "⇝", "leadsto": "⇝", "nRightarrow": "⇏",
        "nmid": "∤", "nparallel": "∦", "nleq": "≰", "ngeq": "≱", "ncong": "≇", "nsim": "≁",
        "subsetneq": "⊊", "supsetneq": "⊋", "nsubseteq": "⊈", "nsupseteq": "⊉",
        "triangleq": "≜", "coloneqq": "≔", "vdash": "⊢", "dashv": "⊣", "vDash": "⊨",
        "lesssim": "≲", "gtrsim": "≳", "llbracket": "⟦", "rrbracket": "⟧",
        "mod": #"\;\mathrm{mod}\;"#, "bmod": #"\;\mathrm{mod}\;"#,
        // Medium space (`\:`, `\>`) is rejected; the thick space is the nearest.
        ":": #"\;"#, ">": #"\;"#,
    ]

    /// Commands dropped entirely: equation numbering, rules, and delimiter
    /// sizing (`\big(` renders as a plain `(`).
    static let dropped: Set<String> = [
        "nonumber", "notag", "hline", "middle",
        "big", "Big", "bigg", "Bigg",
        "bigl", "Bigl", "biggl", "Biggl", "bigr", "Bigr", "biggr", "Biggr",
        "bigm", "Bigm", "biggm", "Biggm",
    ]

    /// Commands dropped together with their one argument.
    static let droppedWithArgument: Set<String> = ["label", "tag", "phantom", "hphantom", "vphantom", "cline"]

    /// `\not` followed by one of these becomes the negated symbol.
    static let negations: [String: String] = [
        "=": "≠", "<": "≮", ">": "≯",
        "in": #"\notin"#, "ni": "∌", "exists": "∄", "mid": "∤", "parallel": "∦",
        "subset": "⊄", "supset": "⊅", "subseteq": "⊈", "supseteq": "⊉",
        "equiv": "≢", "sim": "≁", "cong": "≇", "approx": "≉",
        "le": "≰", "leq": "≰", "ge": "≱", "geq": "≱",
    ]

    /// Commands whose arguments are rewritten into a supported form. The
    /// closure receives the already-normalized arguments.
    struct ArgumentRewrite {
        var optional = false
        var count: Int
        var make: @Sendable (_ optional: String?, _ arguments: [String]) -> String
    }

    static let argumentRewrites: [String: ArgumentRewrite] = [
        "dfrac": .init(count: 2) { _, a in #"{\displaystyle\frac{"# + a[0] + "}{" + a[1] + "}}" },
        "tfrac": .init(count: 2) { _, a in #"{\textstyle\frac{"# + a[0] + "}{" + a[1] + "}}" },
        "cfrac": .init(optional: true, count: 2) { _, a in #"{\displaystyle\frac{"# + a[0] + "}{" + a[1] + "}}" },
        "dbinom": .init(count: 2) { _, a in #"{\displaystyle\binom{"# + a[0] + "}{" + a[1] + "}}" },
        "tbinom": .init(count: 2) { _, a in #"{\textstyle\binom{"# + a[0] + "}{" + a[1] + "}}" },
        "operatorname": .init(count: 1) { _, a in #"\mathrm{"# + a[0] + "}" },
        "boldsymbol": .init(count: 1) { _, a in #"\mathbf{"# + a[0] + "}" },
        "pmb": .init(count: 1) { _, a in #"\mathbf{"# + a[0] + "}" },
        "mathscr": .init(count: 1) { _, a in #"\mathcal{"# + a[0] + "}" },
        "mbox": .init(count: 1) { _, a in #"\text{"# + a[0] + "}" },
        "textnormal": .init(count: 1) { _, a in #"\text{"# + a[0] + "}" },
        "textup": .init(count: 1) { _, a in #"\text{"# + a[0] + "}" },
        "emph": .init(count: 1) { _, a in #"\textit{"# + a[0] + "}" },
        "pmod": .init(count: 1) { _, a in #"\quad(\mathrm{mod}\ "# + a[0] + ")" },
        "overrightarrow": .init(count: 1) { _, a in #"\vec{"# + a[0] + "}" },
        "hspace": .init(count: 1) { _, _ in #"\quad "# },
        "substack": .init(count: 1) { _, a in #"\begin{matrix}"# + a[0] + #"\end{matrix}"# },
        // Approximations: no SwiftMath equivalent, but the content still reads correctly.
        "boxed": .init(count: 1) { _, a in "{" + a[0] + "}" },
        "fbox": .init(count: 1) { _, a in #"\text{"# + a[0] + "}" },
        "underbrace": .init(count: 1) { _, a in #"\underline{"# + a[0] + "}" },
        "overbrace": .init(count: 1) { _, a in #"\overline{"# + a[0] + "}" },
        "overset": .init(count: 2) { _, a in "{" + a[1] + "}^{" + a[0] + "}" },
        "stackrel": .init(count: 2) { _, a in "{" + a[1] + "}^{" + a[0] + "}" },
        "underset": .init(count: 2) { _, a in "{" + a[1] + "}_{" + a[0] + "}" },
        "xrightarrow": .init(optional: true, count: 1) { below, a in arrow(#"\longrightarrow"#, above: a[0], below: below) },
        "xleftarrow": .init(optional: true, count: 1) { below, a in arrow(#"\longleftarrow"#, above: a[0], below: below) },
        "xRightarrow": .init(optional: true, count: 1) { below, a in arrow(#"\Longrightarrow"#, above: a[0], below: below) },
        "xLeftarrow": .init(optional: true, count: 1) { below, a in arrow(#"\Longleftarrow"#, above: a[0], below: below) },
        "xmapsto": .init(optional: true, count: 1) { below, a in arrow(#"\mapsto"#, above: a[0], below: below) },
    ]

    /// Commands that take a `*` variant handled the same way.
    static let starred: Set<String> = ["operatorname", "tag", "hspace"]

    private static func arrow(_ base: String, above: String, below: String?) -> String {
        var out = base
        if !above.isEmpty { out += "^{" + above + "}" }
        if let below, !below.isEmpty { out += "_{" + below + "}" }
        return out
    }
}

// MARK: - Rewriting

/// One normalization pass over a formula. Ranges index the shared `chars`.
private struct Rewriter {
    let chars: [Character]
    /// For each `{` or `[`, the index of its matching closer (escapes skipped); -1 if unmatched.
    private let closing: [Int]
    /// For each `\begin` backslash, where its `\end{name}` starts and ends.
    private let environmentEnds: [Int: (start: Int, after: Int)]

    init(_ chars: [Character]) {
        self.chars = chars
        var closing = Array(repeating: -1, count: chars.count)
        var braces: [Int] = []
        var brackets: [Int] = []
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "\\": i += 1
            case "{": braces.append(i)
            case "}": if let open = braces.popLast() { closing[open] = i }
            case "[": brackets.append(i)
            case "]": if let open = brackets.popLast() { closing[open] = i }
            default: break
            }
            i += 1
        }
        self.closing = closing

        // `\begin{name}` … `\end{name}`, nesting counted per name.
        var ends: [Int: (start: Int, after: Int)] = [:]
        var open: [String: [Int]] = [:]
        let begin = Array(#"\begin{"#)
        let end = Array(#"\end{"#)
        i = 0
        while i < chars.count {
            guard chars[i] == "\\" else {
                i += 1
                continue
            }
            let isBegin = chars[i...].starts(with: begin)
            let isEnd = !isBegin && chars[i...].starts(with: end)
            let brace = i + (isBegin ? begin.count : end.count) - 1
            if isBegin || isEnd, closing[brace] > brace {
                let name = String(chars[(brace + 1)..<closing[brace]])
                if isBegin {
                    open[name, default: []].append(i)
                } else if let start = open[name]?.popLast() {
                    ends[start] = (i, closing[brace] + 1)
                }
                i = closing[brace] + 1
            } else {
                i += 2
            }
        }
        environmentEnds = ends
    }

    func rewrite(_ range: Range<Int>, depth: Int) -> String {
        if depth > LaTeXNormalizer.maxNesting { return String(chars[range]) }
        var out = Output()
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let c = chars[i]
            guard c == "\\", i + 1 < end else {
                out.append(c)
                i += 1
                continue
            }
            var (name, next) = readCommand(at: i, end: end)
            if LaTeXNormalizer.starred.contains(name), next < end, chars[next] == "*" { next += 1 }

            if name == "\\" {
                // Row break; drop a spacing argument like `\\[4pt]`.
                out.emit(#"\\"#)
                i = skipSpacingArgument(at: next, end: end)
            } else if name == "begin", let env = environment(at: i, nameStart: next, end: end) {
                out.emit(rewriteEnvironment(env.name, env.body, depth: depth + 1))
                i = env.after
            } else if let symbol = LaTeXNormalizer.symbols[name] {
                out.emit(symbol)
                i = next
            } else if LaTeXNormalizer.dropped.contains(name) {
                out.emit("")
                i = next
            } else if LaTeXNormalizer.droppedWithArgument.contains(name) {
                out.emit("")
                i = readArgument(at: next, end: end)?.after ?? next
            } else if name == "not", let negation = readNegation(at: next, end: end) {
                out.emit(negation.symbol)
                i = negation.end
            } else if let rule = LaTeXNormalizer.argumentRewrites[name], let call = readArguments(at: next, end: end, rule: rule) {
                out.emit(rule.make(call.optional.map { rewrite($0, depth: depth + 1) }, call.arguments.map { rewrite($0, depth: depth + 1) }))
                i = call.end
            } else {
                out.emit("\\" + name)
                i = next
            }
        }
        return out.text
    }

    /// Output that keeps a control word from fusing with letters that follow
    /// it once something between them was dropped (`\alpha\label{x}b`).
    private struct Output {
        var text = ""
        /// The last thing written was not copied verbatim from the input.
        private var rewritten = false

        mutating func append(_ c: Character) {
            if rewritten, c.isASCIILetter, endsWithControlWord { text.append(" ") }
            rewritten = false
            text.append(c)
        }

        mutating func emit(_ segment: String) {
            if let first = segment.first, first.isASCIILetter, endsWithControlWord { text.append(" ") }
            text += segment
            rewritten = true
        }

        /// Ends in `\letters` with an odd number of backslashes before the letters.
        private var endsWithControlWord: Bool {
            var index = text.endIndex
            var letters = 0
            while index > text.startIndex, letters <= 64 {
                let previous = text.index(before: index)
                guard text[previous].isASCIILetter else { break }
                letters += 1
                index = previous
            }
            guard (1...64).contains(letters) else { return false }
            var backslashes = 0
            while index > text.startIndex, backslashes <= 64 {
                let previous = text.index(before: index)
                guard text[previous] == "\\" else { break }
                backslashes += 1
                index = previous
            }
            return backslashes % 2 == 1
        }
    }

    // MARK: Reading

    /// Reads `\name` (letters) or a one-character control symbol at `i` (the backslash).
    private func readCommand(at i: Int, end: Int) -> (String, Int) {
        var j = i + 1
        if chars[j].isASCIILetter {
            while j < end, chars[j].isASCIILetter { j += 1 }
            return (String(chars[(i + 1)..<j]), j)
        }
        return (String(chars[j]), j + 1)
    }

    private func skipSpaces(from i: Int, end: Int) -> Int {
        var j = i
        while j < end, chars[j].isWhitespace { j += 1 }
        return j
    }

    /// The closer matching the `{` or `[` at `i`, if it lies before `end`.
    private func close(of i: Int, end: Int) -> Int? {
        let close = closing[i]
        return close > i && close < end ? close : nil
    }

    /// One TeX argument: a balanced `{…}` group (the range inside the braces),
    /// a control sequence, or a single character.
    private func readArgument(at i: Int, end: Int) -> (range: Range<Int>, after: Int)? {
        let j = skipSpaces(from: i, end: end)
        guard j < end else { return nil }
        switch chars[j] {
        case "{":
            guard let close = close(of: j, end: end) else { return nil }
            return ((j + 1)..<close, close + 1)
        case "}":
            return nil
        case "\\":
            guard j + 1 < end else { return nil }
            let (_, next) = readCommand(at: j, end: end)
            return (j..<next, next)
        default:
            return (j..<(j + 1), j + 1)
        }
    }

    private func readOptionalArgument(at i: Int, end: Int) -> (range: Range<Int>, after: Int)? {
        let j = skipSpaces(from: i, end: end)
        guard j < end, chars[j] == "[", let close = close(of: j, end: end) else { return nil }
        return ((j + 1)..<close, close + 1)
    }

    private func readArguments(
        at i: Int, end: Int, rule: LaTeXNormalizer.ArgumentRewrite
    ) -> (optional: Range<Int>?, arguments: [Range<Int>], end: Int)? {
        var position = i
        var optional: Range<Int>?
        if rule.optional, let argument = readOptionalArgument(at: position, end: end) {
            optional = argument.range
            position = argument.after
        }
        var arguments: [Range<Int>] = []
        for _ in 0..<rule.count {
            guard let argument = readArgument(at: position, end: end) else { return nil }
            arguments.append(argument.range)
            position = argument.after
        }
        return (optional, arguments, position)
    }

    private func skipSpacingArgument(at i: Int, end: Int) -> Int {
        guard i < end, chars[i] == "[", let close = close(of: i, end: end), close - i <= 16 else { return i }
        let content = String(chars[(i + 1)..<close]).trimmingCharacters(in: .whitespaces)
        let isLength = content.range(of: #"^-?\d*\.?\d+\s*(pt|em|ex|mm|cm|in|mu|bp|pc|sp)$"#, options: .regularExpression) != nil
        return isLength ? close + 1 : i
    }

    private func readNegation(at i: Int, end: Int) -> (symbol: String, end: Int)? {
        let j = skipSpaces(from: i, end: end)
        guard j < end else { return nil }
        if chars[j] == "\\", j + 1 < end {
            let (name, next) = readCommand(at: j, end: end)
            return LaTeXNormalizer.negations[name].map { ($0, next) }
        }
        return LaTeXNormalizer.negations[String(chars[j])].map { ($0, j + 1) }
    }

    // MARK: Environments

    /// `\begin{name}` at `i`: its body and the index after `\end{name}`. An
    /// unclosed environment (mid-stream) runs to `end`.
    private func environment(at i: Int, nameStart: Int, end: Int) -> (name: String, body: Range<Int>, after: Int)? {
        guard nameStart < end, chars[nameStart] == "{", let close = close(of: nameStart, end: end) else { return nil }
        let name = String(chars[(nameStart + 1)..<close])
        if let match = environmentEnds[i], match.after <= end {
            return (name, (close + 1)..<match.start, match.after)
        }
        return (name, (close + 1)..<end, end)
    }

    private func rewriteEnvironment(_ name: String, _ fullBody: Range<Int>, depth: Int) -> String {
        var body = fullBody
        // Drop environment arguments SwiftMath does not take.
        switch name {
        case "array", "alignat", "alignat*", "alignedat":
            if let argument = readArgument(at: body.lowerBound, end: body.upperBound) { body = argument.after..<body.upperBound }
        case _ where name.hasSuffix("matrix*"):
            if let argument = readOptionalArgument(at: body.lowerBound, end: body.upperBound) { body = argument.after..<body.upperBound }
        default:
            break
        }
        let inner = rewrite(body, depth: depth)
        switch name {
        case "equation", "equation*", "displaymath", "math", "subequations":
            return inner
        case "align", "align*", "flalign", "flalign*", "alignat", "alignat*", "alignedat", "aligned", "split":
            return Self.twoColumn("aligned", inner, ifNoColumns: "gather")
        case "eqnarray*":
            return Self.wrap("eqnarray", inner)
        case "gather*", "gathered", "multline", "multline*":
            return Self.wrap("gather", inner)
        case "array", "smallmatrix":
            return Self.wrap("matrix", inner)
        case "cases", "cases*", "dcases":
            return Self.twoColumn("cases", inner, ifNoColumns: nil)
        case _ where name.hasSuffix("matrix*"):
            return Self.wrap(String(name.dropLast()), inner)
        default:
            return Self.wrap(name, inner)
        }
    }

    private static func wrap(_ name: String, _ body: String) -> String {
        #"\begin{"# + name + "}" + body + #"\end{"# + name + "}"
    }

    /// SwiftMath's `aligned` and `cases` need every row to have at most two
    /// columns and at least one row with two. Extra `&`s become `\quad`; with
    /// no `&` at all, alignment environments become `gather` and `cases`
    /// rows get an empty condition column.
    private static func twoColumn(_ name: String, _ body: String, ifNoColumns fallback: String?) -> String {
        let rows = splitRows(Array(body))
        if rows.allSatisfy({ $0.count == 1 }) {
            if let fallback { return wrap(fallback, body) }
            return wrap(name, rows.map { $0[0] + ($0[0].allSatisfy(\.isWhitespace) ? "" : "&") }.joined(separator: #"\\"#))
        }
        let fixed = rows.map { cells -> String in
            guard cells.count > 2 else { return cells.joined(separator: "&") }
            return cells[0] + "&" + cells[1...].joined(separator: #"\quad "#)
        }
        return wrap(name, fixed.joined(separator: #"\\"#))
    }

    /// Splits on top-level `\\` (rows) and `&` (cells), leaving nested groups
    /// and environments intact.
    private static func splitRows(_ chars: [Character]) -> [[String]] {
        var rows: [[String]] = []
        var cells: [String] = []
        var cell = ""
        var braces = 0
        var environments = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let rest = chars[(i + 1)...]
                if braces == 0, environments == 0, chars[i + 1] == "\\" {
                    cells.append(cell)
                    rows.append(cells)
                    cells = []
                    cell = ""
                    i += 2
                    continue
                }
                if rest.starts(with: "begin{") { environments += 1 }
                if rest.starts(with: "end{") { environments -= 1 }
                cell.append(c)
                cell.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "{" { braces += 1 }
            if c == "}" { braces -= 1 }
            if c == "&", braces == 0, environments == 0 {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(c)
            }
            i += 1
        }
        cells.append(cell)
        rows.append(cells)
        return rows
    }
}

extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
}
