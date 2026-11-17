import Foundation
import HermesKit

/// An assistant message as the desktop app lays it out: HermesKit's `MarkdownPresentation`
/// (the parts the Mac app shows: prose runs, code blocks, tables), in the wire shape of
/// docs/desktop-bridge.md, "Markdown". Parsing is HermesKit's; this only spells it out.
struct MarkdownPart: Encodable, Sendable, Equatable {
    struct Code: Encodable, Sendable, Equatable {
        /// A run of the code and what it is (`CodeHighlighter.Kind`), for its colour.
        struct Span: Encodable, Sendable, Equatable {
            var text: String
            var kind: String
        }

        var language: String?
        var text: String
        var isClosed: Bool
        /// The code cut into coloured spans (`CodeHighlighter`); their texts joined are `text`.
        var spans: [Span]

        init(language: String?, text: String, isClosed: Bool) {
            self.language = language
            self.text = text
            self.isClosed = isClosed
            spans = CodeHighlighter.spans(text, language: language).map { Span(text: $0.text, kind: $0.kind.rawValue) }
        }
    }

    struct Table: Encodable, Sendable, Equatable {
        /// `none`, `leading`, `center` or `trailing`, one per column.
        var alignments: [String]
        var header: [[MarkdownRun]]
        var rows: [[[MarkdownRun]]]
    }

    /// The index of the part's first block; stable while the streaming tail is re-parsed.
    var id: Int
    var prose: [MarkdownRun]?
    var code: Code?
    var table: Table?

    init(_ part: MarkdownPresentation.Part) {
        id = part.id
        switch part.content {
        case .prose(let selection):
            prose = selection.runs.map(MarkdownRun.init)
        case .code(let language, let text, let isClosed):
            code = Code(language: language, text: text, isClosed: isClosed)
        case .table(let table):
            self.table = Table(
                alignments: table.alignments.map {
                    switch $0 {
                    case .none: "none"
                    case .leading: "leading"
                    case .center: "center"
                    case .trailing: "trailing"
                    }
                },
                header: table.header.map(Self.cell),
                rows: table.rows.map { $0.map(Self.cell) })
        }
    }

    /// A table cell's runs, as the Mac lays out each cell: one paragraph of the cell's inlines.
    private static func cell(_ inlines: [MarkdownInline]) -> [MarkdownRun] {
        MarkdownSelection(document: MarkdownDocument(blocks: [.paragraph(inlines)])).runs.map(MarkdownRun.init)
    }

    static func parts(_ text: String, streaming: Bool) -> [MarkdownPart] {
        MarkdownPresentation(parsing: text, streaming: streaming).parts.map(MarkdownPart.init)
    }
}

/// One run of `MarkdownSelection`: text with its role and styles. Flags that are off and
/// empty lists are left out, so a long transcript stays small on the wire.
struct MarkdownRun: Encodable, Sendable, Equatable {
    var text: String
    /// `body`, `heading`, `listMarker`, `codeLanguage`, `code`, `tableHeader`, `tableCell`,
    /// `math` or `separator`.
    var role: String
    var level: Int?
    var bold: Bool
    var italic: Bool
    var strike: Bool
    var inlineCode: Bool
    var link: String?
    /// For `math`: the LaTeX source, and whether it is display math.
    var math: String?
    var display: Bool
    /// Outermost first: `list`, `orderedList` or `quote`.
    var indents: [String]
    /// Space above the paragraph this run starts: `block` or `listItem`.
    var gap: String?

    init(_ run: MarkdownSelection.Run) {
        // A math run shows U+FFFC on the Mac (an attachment); here its source stands in.
        text = run.math?.source ?? run.text
        switch run.role {
        case .body: role = "body"
        case .heading(let level): role = "heading"; self.level = level
        case .listMarker: role = "listMarker"
        case .codeLanguage: role = "codeLanguage"
        case .code: role = "code"
        case .tableHeader: role = "tableHeader"
        case .tableCell: role = "tableCell"
        case .math: role = "math"
        case .separator: role = "separator"
        }
        bold = run.bold
        italic = run.italic
        strike = run.strike
        inlineCode = run.inlineCode
        link = run.link
        math = run.math?.source
        display = run.math?.isDisplay ?? false
        indents = run.indents.map {
            switch $0 {
            case .list(let ordered): ordered ? "orderedList" : "list"
            case .quote: "quote"
            }
        }
        gap = switch run.gap {
        case .none: nil
        case .block: "block"
        case .listItem: "listItem"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text, role, level, bold, italic, strike, inlineCode, link, math, display, indents, gap
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(level, forKey: .level)
        if bold { try container.encode(true, forKey: .bold) }
        if italic { try container.encode(true, forKey: .italic) }
        if strike { try container.encode(true, forKey: .strike) }
        if inlineCode { try container.encode(true, forKey: .inlineCode) }
        try container.encodeIfPresent(link, forKey: .link)
        try container.encodeIfPresent(math, forKey: .math)
        if display { try container.encode(true, forKey: .display) }
        if !indents.isEmpty { try container.encode(indents, forKey: .indents) }
        try container.encodeIfPresent(gap, forKey: .gap)
    }
}

/// Finished messages are parsed once, as on the Mac (`MarkdownDocumentCache`): a chat
/// snapshot is rebuilt on every streamed delta, and only the streaming message changes.
@MainActor
final class MarkdownCache {
    private var finished: [String: [MarkdownPart]] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 500) { self.limit = limit }

    func parts(_ text: String, streaming: Bool) -> [MarkdownPart] {
        if streaming { return MarkdownPart.parts(text, streaming: true) }
        if let parts = finished[text] { return parts }
        let parts = MarkdownPart.parts(text, streaming: false)
        finished[text] = parts
        order.append(text)
        if order.count > limit { finished[order.removeFirst()] = nil }
        return parts
    }
}
