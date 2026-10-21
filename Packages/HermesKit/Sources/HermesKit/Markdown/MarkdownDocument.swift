import Foundation

/// A parsed assistant message: CommonMark/GFM blocks plus LaTeX math.
///
/// Parsing is pure and platform-neutral so the apps only map the tree to views.
/// The dialect is what chat models emit, not full CommonMark: see
/// `MarkdownParser` for the supported subset and the deliberate deviations.
public struct MarkdownDocument: Sendable, Hashable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    /// Parses `text`. Pass `streaming: true` while deltas are still arriving:
    /// unclosed fences and math stay stable instead of reflowing, and a table
    /// header shows as a table before its delimiter row arrives.
    public init(parsing text: String, streaming: Bool = false) {
        self.blocks = Tracing.measure("Markdown parse") { MarkdownParser(streaming: streaming).parse(text) }
    }
}

public indirect enum MarkdownBlock: Sendable, Hashable {
    case paragraph([MarkdownInline])
    case heading(level: Int, content: [MarkdownInline])
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    /// Fenced code. `isClosed` is false while the closing fence has not arrived.
    case code(language: String?, code: String, isClosed: Bool)
    /// Display math (`$$…$$`, `\[…\]`, or a bare `\begin{align}`-style block).
    case math(MathSnippet)
    case table(MarkdownTable)
    case thematicBreak
}

public struct MarkdownList: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        /// Task-list state: `nil` for a plain item, else whether `[x]` was ticked.
        public var checkbox: Bool?
        public var blocks: [MarkdownBlock]

        public init(checkbox: Bool? = nil, blocks: [MarkdownBlock]) {
            self.checkbox = checkbox
            self.blocks = blocks
        }
    }

    /// The first number of an ordered list; `nil` for a bullet list.
    public var start: Int?
    public var items: [Item]

    public var isOrdered: Bool { start != nil }

    public init(start: Int?, items: [Item]) {
        self.start = start
        self.items = items
    }
}

public struct MarkdownTable: Sendable, Hashable {
    public enum Alignment: Sendable, Hashable {
        case none, leading, center, trailing
    }

    public var alignments: [Alignment]
    public var header: [[MarkdownInline]]
    /// Every row has exactly `header.count` cells (padded or truncated).
    public var rows: [[[MarkdownInline]]]

    public init(alignments: [Alignment], header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

public indirect enum MarkdownInline: Sendable, Hashable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(destination: String, content: [MarkdownInline])
    case math(MathSnippet)
    case lineBreak
}

/// A piece of LaTeX as written, plus the form rewritten for a native renderer.
public struct MathSnippet: Sendable, Hashable {
    /// The source between the delimiters, trimmed. Shown when rendering fails.
    public var source: String
    /// `source` after `LaTeXNormalizer`; feed this to the renderer.
    public var latex: String
    /// Display style (`$$`, `\[`, environments) rather than inline text style.
    public var isDisplay: Bool
    /// False while the closing delimiter has not arrived (streaming).
    public var isClosed: Bool

    public init(source: String, isDisplay: Bool, isClosed: Bool = true) {
        self.source = source
        self.latex = LaTeXNormalizer.normalize(source)
        self.isDisplay = isDisplay
        self.isClosed = isClosed
    }
}

extension MarkdownInline {
    /// The text a reader would see, without markup; math keeps its source.
    public var plainText: String {
        switch self {
        case .text(let text), .code(let text): text
        case .emphasis(let children), .strong(let children), .strikethrough(let children),
             .link(_, let children):
            children.plainText
        case .math(let snippet): snippet.source
        case .lineBreak: "\n"
        }
    }
}

extension Array where Element == MarkdownInline {
    public var plainText: String { map(\.plainText).joined() }
}
