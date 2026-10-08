import Foundation

/// A message is a sequence of selectable prose runs and independently laid out
/// code/table components. Indices refer to parsed blocks and stay stable while
/// the parser replaces the streaming tail.
public struct MarkdownPresentation: Sendable, Hashable {
    public struct Part: Sendable, Hashable, Identifiable {
        public enum Content: Sendable, Hashable {
            case prose(MarkdownSelection)
            case code(language: String?, text: String, isClosed: Bool)
            case table(MarkdownTable)
        }

        public let id: Int
        public let content: Content
    }

    public let parts: [Part]

    public init(document: MarkdownDocument) {
        var parts: [Part] = []
        var prose: [MarkdownBlock] = []
        var proseStart = 0

        func flush() {
            guard !prose.isEmpty else { return }
            parts.append(Part(id: proseStart, content: .prose(MarkdownSelection(document: MarkdownDocument(blocks: prose)))))
            prose.removeAll(keepingCapacity: true)
        }

        for (index, block) in document.blocks.enumerated() {
            switch block {
            case .code(let language, let text, let isClosed):
                flush()
                parts.append(Part(id: index, content: .code(language: language, text: text, isClosed: isClosed)))
            case .table(let table):
                flush()
                parts.append(Part(id: index, content: .table(table)))
            default:
                if prose.isEmpty { proseStart = index }
                prose.append(block)
            }
        }
        flush()
        self.parts = parts
    }

    public init(parsing source: String, streaming: Bool = false) {
        self.init(document: MarkdownDocument(parsing: source, streaming: streaming))
    }
}
