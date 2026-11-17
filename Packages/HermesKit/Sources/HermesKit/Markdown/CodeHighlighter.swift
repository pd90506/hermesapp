import Foundation

/// Syntax colouring for fenced code: the code cut into consecutive spans, each with what
/// it is (keyword, string, comment, …), for an app to colour.
///
/// A small lexer, not a parser: per-language keywords, comment and string syntax, and a
/// few shape rules (numbers, a capitalised name is a type, a name before `(` is a call).
/// It never drops or reorders text: the spans' texts joined are the code. An unknown or
/// missing language still gets strings, numbers and both comment styles a reply is
/// likely to use, so a fence without a language is coloured too. An unclosed string or
/// block comment (a fence still streaming in) runs to the end of the code.
public enum CodeHighlighter {
    public enum Kind: String, Sendable, Hashable {
        case plain, keyword, string, comment, number, type, function, literal
    }

    public struct Span: Sendable, Hashable {
        public var text: String
        public var kind: Kind

        public init(_ text: String, _ kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// Code over this many characters is left plain: colouring is a nicety, and the lexer
    /// walks every character.
    public static let maxLength = 60_000

    public static func spans(_ code: String, language: String?) -> [Span] {
        guard code.count <= maxLength else { return code.isEmpty ? [] : [Span(code, .plain)] }
        var lexer = Lexer(chars: Array(code), grammar: Grammar.for(language))
        return lexer.run()
    }

    // MARK: - Grammars

    struct Grammar {
        var keywords: Set<String> = []
        var literals: Set<String> = ["true", "false", "null", "nil", "None", "True", "False", "undefined"]
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        var tripleQuotes = false
        /// `$name` variables (shell) are coloured as keywords would be noisy; as types.
        var dollarVariables = false
        var caseInsensitiveKeywords = false
        /// JSON and YAML keys: a string followed by `:` reads as a name, not a value.
        var keysBeforeColon = false

        static func `for`(_ language: String?) -> Grammar {
            let name = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            switch name {
            case "swift":
                return cLike(["associatedtype", "actor", "any", "as", "async", "await", "break", "case", "catch",
                              "class", "continue", "default", "defer", "do", "else", "enum", "extension",
                              "fallthrough", "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
                              "inout", "internal", "is", "let", "nonisolated", "open", "operator", "private",
                              "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some",
                              "static", "struct", "subscript", "super", "switch", "throw", "throws", "try",
                              "typealias", "var", "where", "while", "mutating", "override", "final", "lazy",
                              "weak", "unowned", "convenience", "required", "deinit", "get", "set"])
            case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs":
                var g = cLike(["async", "await", "break", "case", "catch", "class", "const", "continue",
                               "debugger", "default", "delete", "do", "else", "export", "extends", "finally",
                               "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let",
                               "new", "of", "return", "static", "super", "switch", "this", "throw", "try", "type",
                               "typeof", "var", "void", "while", "yield", "enum", "implements", "private",
                               "public", "protected", "readonly", "as", "keyof", "declare", "namespace"])
                g.quotes.insert("`")
                return g
            case "java", "kotlin", "kt", "scala", "groovy":
                return cLike(["abstract", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
                              "continue", "default", "do", "double", "else", "enum", "extends", "final",
                              "finally", "float", "for", "fun", "if", "implements", "import", "instanceof", "int",
                              "interface", "long", "new", "object", "override", "package", "private", "protected",
                              "public", "return", "short", "static", "super", "switch", "this", "throw", "throws",
                              "try", "val", "var", "void", "when", "while", "data", "is", "in", "companion"])
            case "c", "h", "cpp", "c++", "cc", "hpp", "cxx", "objc", "objective-c", "cs", "csharp", "c#":
                return cLike(["auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr",
                              "continue", "default", "delete", "do", "double", "else", "enum", "explicit",
                              "extern", "float", "for", "friend", "goto", "if", "inline", "int", "long",
                              "namespace", "new", "noexcept", "operator", "private", "protected", "public",
                              "return", "short", "signed", "sizeof", "static", "struct", "switch", "template",
                              "this", "throw", "try", "typedef", "typename", "union", "unsigned", "using",
                              "virtual", "void", "volatile", "while", "nullptr", "override", "var", "string",
                              "async", "await", "foreach", "in", "is", "readonly", "sealed", "get", "set",
                              "#include", "#define", "#if", "#ifdef", "#ifndef", "#endif", "#pragma"])
            case "go", "golang":
                var g = cLike(["break", "case", "chan", "const", "continue", "default", "defer", "else",
                               "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                               "package", "range", "return", "select", "struct", "switch", "type", "var"])
                g.quotes.insert("`")
                return g
            case "rust", "rs":
                var g = cLike(["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                               "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                               "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
                               "super", "trait", "type", "unsafe", "use", "where", "while"])
                g.quotes = ["\""]  // 'a is a lifetime, not a string
                return g
            case "dart":
                return cLike(["abstract", "as", "async", "await", "break", "case", "catch", "class", "const",
                              "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for",
                              "if", "import", "in", "is", "late", "library", "new", "required", "return",
                              "static", "super", "switch", "this", "throw", "try", "var", "void", "while",
                              "with", "yield", "sealed", "part", "show", "hide"])
            case "python", "py", "python3":
                return Grammar(keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue",
                                          "def", "del", "elif", "else", "except", "finally", "for", "from",
                                          "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
                                          "pass", "raise", "return", "try", "while", "with", "yield", "match",
                                          "case", "self"],
                               lineComments: ["#"], tripleQuotes: true)
            case "ruby", "rb":
                return Grammar(keywords: ["begin", "class", "def", "do", "else", "elsif", "end", "ensure", "if",
                                          "module", "next", "require", "rescue", "return", "self", "then",
                                          "unless", "until", "when", "while", "yield"],
                               lineComments: ["#"])
            case "sh", "bash", "shell", "zsh", "console", "shellsession":
                return Grammar(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                                          "until", "case", "esac", "function", "return", "export", "local",
                                          "sudo", "echo", "cd", "set", "unset", "source"],
                               lineComments: ["#"], dollarVariables: true)
            case "ps1", "powershell", "pwsh":
                return Grammar(keywords: ["if", "else", "elseif", "foreach", "for", "while", "do", "function",
                                          "param", "return", "switch", "try", "catch", "finally", "throw", "in",
                                          "begin", "process", "end"],
                               lineComments: ["#"], blockComment: ("<#", "#>"), dollarVariables: true,
                               caseInsensitiveKeywords: true)
            case "sql", "postgres", "postgresql", "mysql", "sqlite":
                return Grammar(keywords: ["select", "from", "where", "and", "or", "not", "insert", "into",
                                          "values", "update", "set", "delete", "create", "table", "drop",
                                          "alter", "join", "left", "right", "inner", "outer", "on", "as",
                                          "group", "by", "order", "having", "limit", "offset", "distinct",
                                          "union", "all", "primary", "key", "foreign", "references", "index",
                                          "is", "null", "in", "like", "between", "case", "when", "then", "else",
                                          "end", "with", "returning", "asc", "desc", "count", "default"],
                               lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""],
                               caseInsensitiveKeywords: true)
            case "json", "jsonc", "json5":
                return Grammar(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""],
                               keysBeforeColon: true)
            case "yaml", "yml", "toml", "ini":
                return Grammar(lineComments: ["#"], keysBeforeColon: true)
            case "html", "xml", "svg", "vue":
                return Grammar(literals: [], blockComment: ("<!--", "-->"))
            case "css", "scss", "less":
                return Grammar(literals: [], lineComments: name == "css" ? [] : ["//"], blockComment: ("/*", "*/"))
            default:
                // Unknown: what most replies use.
                return Grammar(lineComments: ["//", "#"], blockComment: ("/*", "*/"))
            }
        }

        static func cLike(_ keywords: Set<String>) -> Grammar {
            Grammar(keywords: keywords, lineComments: ["//"], blockComment: ("/*", "*/"))
        }
    }

    // MARK: - Lexer

    struct Lexer {
        let chars: [Character]
        let grammar: Grammar
        var i = 0
        var spans: [Span] = []

        mutating func run() -> [Span] {
            while i < chars.count {
                if let close = blockCommentOpen() {
                    take(until: close, kind: .comment)
                } else if lineCommentStarts() {
                    var j = i
                    while j < chars.count, chars[j] != "\n" { j += 1 }
                    emit(j, .comment)
                } else if grammar.tripleQuotes, let q = tripleQuote() {
                    take(until: String(repeating: q, count: 3), kind: .string, from: i + 3)
                } else if grammar.quotes.contains(chars[i]) {
                    string(quote: chars[i])
                } else if grammar.dollarVariables, chars[i] == "$", i + 1 < chars.count,
                          chars[i + 1].isLetter || chars[i + 1] == "_" || chars[i + 1] == "{" {
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || "_{}".contains(chars[j]) { j += 1 }
                    emit(j, .type)
                } else if chars[i].isNumber, !previousIsWordCharacter {
                    number()
                } else if chars[i].isLetter || chars[i] == "_" || (chars[i] == "#" && nextIsLetter) || chars[i] == "@" {
                    word()
                } else {
                    emit(i + 1, .plain)
                }
            }
            return spans
        }

        var previousIsWordCharacter: Bool {
            i > 0 && (chars[i - 1].isLetter || chars[i - 1] == "_")
        }

        var nextIsLetter: Bool { i + 1 < chars.count && chars[i + 1].isLetter }

        func starts(with token: String, at index: Int) -> Bool {
            var j = index
            for c in token {
                guard j < chars.count, chars[j] == c else { return false }
                j += 1
            }
            return true
        }

        func blockCommentOpen() -> String? {
            guard let block = grammar.blockComment, starts(with: block.open, at: i) else { return nil }
            return block.close
        }

        func lineCommentStarts() -> Bool {
            grammar.lineComments.contains { marker in
                guard starts(with: marker, at: i) else { return false }
                // `#` begins a comment only at a word boundary: `a#b`, `#include` (C) and
                // `$#` stay as they are.
                if marker == "#" {
                    if i > 0, !chars[i - 1].isWhitespace { return false }
                }
                return true
            }
        }

        func tripleQuote() -> Character? {
            for q in ["\"", "'"] as [Character] where starts(with: String(repeating: q, count: 3), at: i) {
                return q
            }
            return nil
        }

        /// From `from` (default: after the opener at `i`) to just past `close`, or the end.
        mutating func take(until close: String, kind: Kind, from start: Int? = nil) {
            var j = start ?? (i + 1)
            while j < chars.count, !starts(with: close, at: j) { j += 1 }
            emit(min(chars.count, j + close.count), kind)
        }

        mutating func string(quote: Character) {
            var j = i + 1
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == quote { j += 1; break }
                // A plain quote ends at the line's end (an apostrophe in prose, or a line
                // still streaming in); a backtick string may span lines.
                if chars[j] == "\n", quote != "`" { break }
                j += 1
            }
            j = min(j, chars.count)
            var kind = Kind.string
            if grammar.keysBeforeColon {
                var k = j
                while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                if k < chars.count, chars[k] == ":" { kind = .type }
            }
            emit(j, kind)
        }

        mutating func number() {
            var j = i
            while j < chars.count, chars[j].isNumber || chars[j].isLetter || chars[j] == "." || chars[j] == "_" {
                // `1..<5`: a range, not a decimal point.
                if chars[j] == ".", j + 1 < chars.count, chars[j + 1] == "." { break }
                j += 1
            }
            emit(j, .number)
        }

        mutating func word() {
            var j = i + 1
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "-" && grammar.keysBeforeColon {
                j += 1
            }
            let text = String(chars[i..<j])
            let keyword = grammar.caseInsensitiveKeywords ? grammar.keywords.contains(text.lowercased())
                                                          : grammar.keywords.contains(text)
            var next = j
            while next < chars.count, chars[next] == " " { next += 1 }
            let kind: Kind
            if keyword {
                kind = .keyword
            } else if grammar.literals.contains(text) {
                kind = .literal
            } else if grammar.keysBeforeColon, next < chars.count, chars[next] == ":" {
                kind = .type
            } else if text.hasPrefix("@") {
                kind = .keyword
            } else if next < chars.count, chars[next] == "(" {
                kind = .function
            } else if let first = text.first, first.isUppercase, text.contains(where: \.isLowercase) {
                kind = .type
            } else {
                kind = .plain
            }
            emit(j, kind)
        }

        /// Adds `chars[i..<end]` as a span of `kind`, merged into the last if it is plain too.
        mutating func emit(_ end: Int, _ kind: Kind) {
            let end = max(end, i + 1)
            let text = String(chars[i..<min(end, chars.count)])
            if let last = spans.last, last.kind == kind, kind == .plain {
                spans[spans.count - 1].text += text
            } else {
                spans.append(Span(text, kind))
            }
            i = min(end, chars.count)
        }
    }
}
