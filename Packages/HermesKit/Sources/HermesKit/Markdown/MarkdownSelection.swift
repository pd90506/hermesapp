import Foundation

/// A platform-neutral attributed transcript of one Markdown message. Each run
/// carries the presentation attributes needed by the native text controls, and
/// its own clipboard spelling: a list marker shows `•` but copies `- `, a block
/// separator shows one line break but copies a blank line, and math copies its
/// delimited LaTeX source.
public struct MarkdownSelection: Sendable, Hashable {
    public struct Run: Sendable, Hashable {
        public enum Role: Sendable, Hashable {
            case body, heading(Int), listMarker, codeLanguage, code, tableHeader, tableCell, math
            /// The line break between two blocks, list items or table rows.
            case separator
        }

        /// One level of nesting, outermost first. The renderer turns each into a
        /// leading indent; a quote also gets a bar.
        public enum Indent: Sendable, Hashable {
            case list(ordered: Bool), quote
        }

        /// Space above the paragraph this run starts.
        public enum Gap: Sendable, Hashable {
            case none, block, listItem
        }

        public var text: String
        public var copyText: String
        public var role: Role
        public var bold: Bool
        public var italic: Bool
        public var strike: Bool
        public var inlineCode: Bool
        public var link: String?
        public var math: MathSnippet?
        public var indents: [Indent]
        public var gap: Gap

        public init(text: String, copyText: String? = nil, role: Role = .body,
                    bold: Bool = false, italic: Bool = false, strike: Bool = false,
                    inlineCode: Bool = false, link: String? = nil, math: MathSnippet? = nil,
                    indents: [Indent] = [], gap: Gap = .none) {
            self.text = text
            self.copyText = copyText ?? text
            self.role = role
            self.bold = bold
            self.italic = italic
            self.strike = strike
            self.inlineCode = inlineCode
            self.link = link
            self.math = math
            self.indents = indents
            self.gap = gap
        }

        public var isQuoted: Bool { indents.contains(.quote) }

        /// Copied whole whenever any part is selected, because what is shown is not
        /// what is copied: math, list markers, separators and the code language label.
        public var copiesAsUnit: Bool { math != nil || copyText != text }
    }

    /// Set on every rendered run, so adjacent runs never merge when copying.
    public static let runIndexAttribute = NSAttributedString.Key("HermesRunIndex")
    /// Set on runs that copy as a unit (see `Run.copiesAsUnit`); the value is the
    /// text to place on the clipboard.
    public static let copyTextAttribute = NSAttributedString.Key("HermesCopyText")

    /// The attributes that make `copyText(from:range:)` work, for run `index`.
    public func copyAttributes(forRunAt index: Int) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [Self.runIndexAttribute: index]
        if runs[index].copiesAsUnit { attributes[Self.copyTextAttribute] = runs[index].copyText }
        return attributes
    }

    /// The clipboard text for a native selection over text rendered from runs
    /// tagged with `copyAttributes(forRunAt:)`.
    public static func copyText(from attributed: NSAttributedString, range: NSRange) -> String {
        guard range.location >= 0, NSMaxRange(range) <= attributed.length else { return "" }
        var result = ""
        // A run can arrive in pieces (the text system substitutes a fallback font
        // for a glyph such as ☐); a unit is copied once per run.
        var lastUnit: Int?
        attributed.enumerateAttributes(in: range) { attributes, part, _ in
            let index = attributes[runIndexAttribute] as? Int
            if let copy = attributes[copyTextAttribute] as? String {
                if index == nil || index != lastUnit { result += copy }
                lastUnit = index
            } else {
                result += (attributed.string as NSString).substring(with: part)
                lastUnit = nil
            }
        }
        return result
    }

    public let runs: [Run]
    public var plainText: String { runs.map(\.copyText).joined() }

    public init(document: MarkdownDocument) {
        var builder = Builder()
        builder.blocks(document.blocks)
        runs = builder.runs
    }

    public init(parsing source: String, streaming: Bool = false) {
        self.init(document: MarkdownDocument(parsing: source, streaming: streaming))
    }

    private struct Builder {
        var runs: [Run] = []
        var indents: [Run.Indent] = []
        /// Space above the next run; set after a separator.
        var pendingGap = Run.Gap.none

        mutating func add(_ text: String, copy: String? = nil, role: Run.Role, bold: Bool = false,
                          italic: Bool = false, strike: Bool = false,
                          inlineCode: Bool = false, link: String? = nil, math: MathSnippet? = nil) {
            guard !text.isEmpty else { return }
            runs.append(Run(text: text, copyText: copy, role: role, bold: bold, italic: italic,
                            strike: strike, inlineCode: inlineCode, link: link, math: math,
                            indents: indents, gap: pendingGap))
            pendingGap = .none
        }

        /// One line break on screen (paragraph spacing provides the gap), and a
        /// blank line on the clipboard between blocks.
        mutating func separator(copy: String, gap: Run.Gap) {
            add("\n", copy: copy, role: .separator)
            pendingGap = gap
        }

        mutating func blocks(_ blocks: [MarkdownBlock], separator copy: String = "\n\n") {
            for (index, block) in blocks.enumerated() {
                if index > 0 { separator(copy: copy, gap: .block) }
                switch block {
                case .paragraph(let content): inlines(content, role: .body)
                case .heading(let level, let content): inlines(content, role: .heading(level))
                case .blockQuote(let nested):
                    indents.append(.quote)
                    self.blocks(nested)
                    indents.removeLast()
                case .list(let list): self.list(list)
                case .code(let language, let code, _):
                    // The label line also holds the Copy button; it is not copied.
                    add((language ?? "") + "\n", copy: "", role: .codeLanguage)
                    add(code, role: .code)
                case .math(let snippet): math(snippet)
                case .table(let table):
                    tableRow(table.header, role: .tableHeader)
                    for row in table.rows {
                        separator(copy: "\n", gap: .none)
                        tableRow(row, role: .tableCell)
                    }
                case .thematicBreak: add("────────", role: .body)
                }
            }
        }

        mutating func list(_ list: MarkdownList) {
            let depth = indents.filter { $0 != .quote }.count
            let indentation = String(repeating: "  ", count: depth)
            indents.append(.list(ordered: list.isOrdered))
            for (index, item) in list.items.enumerated() {
                if index > 0 { separator(copy: "\n", gap: .listItem) }
                let shown: String
                let copied: String
                if let checked = item.checkbox {
                    shown = checked ? "☑" : "☐"
                    copied = checked ? "- [x] " : "- [ ] "
                } else if let start = list.start {
                    shown = "\(start + index)."
                    copied = "\(start + index). "
                } else {
                    shown = ["•", "◦", "▪︎"][depth % 3]
                    copied = "- "
                }
                // Tabs place the marker in its column and the text at the hanging indent.
                add("\t\(shown)\t", copy: indentation + copied, role: .listMarker)
                blocks(item.blocks, separator: "\n")
            }
            indents.removeLast()
        }

        mutating func tableRow(_ cells: [[MarkdownInline]], role: Run.Role) {
            for (index, cell) in cells.enumerated() {
                if index > 0 { add("\t", role: role) }
                inlines(cell, role: role)
            }
        }

        /// Copies with its delimiters, so a paste into Markdown keeps its meaning.
        /// A formula still streaming in has no closing delimiter yet.
        mutating func math(_ snippet: MathSnippet) {
            let open = snippet.isDisplay ? "$$" : "$"
            add("\u{FFFC}", copy: open + snippet.source + (snippet.isClosed ? open : ""),
                role: .math, math: snippet)
        }

        mutating func inlines(_ values: [MarkdownInline], role: Run.Role,
                              bold: Bool = false, italic: Bool = false,
                              strike: Bool = false, link: String? = nil) {
            for value in values {
                switch value {
                case .text(let text): add(text, role: role, bold: bold, italic: italic, strike: strike, link: link)
                case .code(let code): add(code, role: role, bold: bold, italic: italic, strike: strike,
                                          inlineCode: true, link: link)
                case .strong(let nested): inlines(nested, role: role, bold: true, italic: italic, strike: strike, link: link)
                case .emphasis(let nested): inlines(nested, role: role, bold: bold, italic: true, strike: strike, link: link)
                case .strikethrough(let nested): inlines(nested, role: role, bold: bold, italic: italic, strike: true, link: link)
                case .link(let destination, let nested):
                    inlines(nested, role: role, bold: bold, italic: italic, strike: strike, link: destination)
                case .math(let snippet): math(snippet)
                case .lineBreak: add("\n", role: role)
                }
            }
        }
    }
}

/// Export only the loaded, visible conversation rows. Reasoning is intentionally
/// omitted; it is a disclosure beside a reply, not a separate message.
public enum ConversationMarkdown {
    public static func messageSource(for item: TranscriptItem) -> String {
        if !item.text.isEmpty || item.role != .tool { return item.text }
        return [item.toolName, item.detail].compactMap { $0 }.joined(separator: "\n")
    }

    /// The row whose action bar stays shown without hover: the last user message (not
    /// a background notice, which has no bar),
    /// or assistant message with text. Tool and system rows have no bar, so a tool
    /// call running after a reply leaves the bar on that reply; an assistant row with
    /// no text yet has none either (nothing to copy), so while the reply is awaited
    /// the bar stays on the prompt.
    public static func newestMessageID(in items: [TranscriptItem]) -> String? {
        items.last { ($0.role == .user && $0.backgroundNotice == nil) || hasActionBar($0) }?.id
    }

    /// An assistant row gets an action bar once it has text to copy.
    public static func hasActionBar(_ item: TranscriptItem) -> Bool {
        item.role == .assistant && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func export(_ items: [TranscriptItem]) -> String {
        items.map { item in
            let role: String
            switch item.role {
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .tool: role = "Tool"
            case .system: role = "System"
            }
            return "## \(role)\n\n\(messageSource(for: item))"
        }.joined(separator: "\n\n")
    }
}
