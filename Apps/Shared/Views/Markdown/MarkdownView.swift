import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders Markdown parsed by HermesKit's `MarkdownDocument`; layout only.
struct MarkdownView: View, Equatable {
    let text: String
    /// Still receiving deltas: parse leniently and hold back unclosed math.
    let isStreaming: Bool

    @ScaledMetric(relativeTo: .body) private var mathSize = MarkdownMetrics.bodySize

    var body: some View {
        MarkdownBlocks(blocks: MarkdownDocumentCache.document(for: text, streaming: isStreaming).blocks)
            .environment(\.markdownIsStreaming, isStreaming)
            .environment(\.markdownMathSize, mathSize)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isStreaming == rhs.isStreaming && lhs.text == rhs.text
    }
}

/// Finished messages are parsed once and reused when rows scroll back into
/// view. Streaming prefixes are parsed fresh each time and not cached.
@MainActor
private enum MarkdownDocumentCache {
    private final class Entry {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()

    static func document(for text: String, streaming: Bool) -> MarkdownDocument {
        if streaming { return MarkdownDocument(parsing: text, streaming: true) }
        let key = text as NSString
        if let entry = cache.object(forKey: key) { return entry.document }
        let document = MarkdownDocument(parsing: text)
        cache.setObject(Entry(document), forKey: key)
        return document
    }
}

struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Positions are stable identities: streaming only appends or edits the tail.
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let content):
            InlineText(content: content)
        case .heading(let level, let content):
            InlineText(content: content, mathScale: Self.headingScale(level))
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case .blockQuote(let blocks):
            MarkdownBlocks(blocks: blocks)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                }
        case .list(let list):
            ListView(list: list)
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code)
        case .math(let snippet):
            MathBlockView(snippet: snippet)
        case .table(let table):
            TableView(table: table)
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: 1.35
        case 2: 1.2
        default: 1
        }
    }
}

private struct ListView: View {
    let list: MarkdownList
    @Environment(\.markdownListDepth) private var depth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list.items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index)
                        .frame(minWidth: list.isOrdered ? 20 : 12, alignment: .trailing)
                    MarkdownBlocks(blocks: list.items[index].blocks)
                        .environment(\.markdownListDepth, depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        if let checked = list.items[index].checkbox {
            Image(systemName: checked ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
        } else if let start = list.start {
            Text("\(start + index).").monospacedDigit()
        } else {
            Text(["•", "◦", "▪︎"][depth % 3]).foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(code) }
                    .labelStyle(.iconOnly)
                    .hoverButtonStyle(.rounded, padding: 4)
                    .font(.caption)
                    .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            // Long lines scroll sideways instead of widening the transcript.
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding([.horizontal, .bottom], 10)
                    .padding(.top, 4)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}

private struct TableView: View {
    let table: MarkdownTable
    /// Columns with long cells wrap at a fixed width; the rest size to fit.
    private let wideColumns: Set<Int>

    init(table: MarkdownTable) {
        self.table = table
        var wide = Set<Int>()
        for column in table.header.indices {
            let cells = [table.header[column]] + table.rows.map { $0[column] }
            if cells.contains(where: { Self.estimatedWidth($0.plainText) > 40 }) { wide.insert(column) }
        }
        wideColumns = wide
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column: column).bold()
                    }
                }
                Divider()
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(table.rows[row][column], column: column)
                        }
                    }
                    if row < table.rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .padding(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func cell(_ content: [MarkdownInline], column: Int) -> some View {
        let alignment = Self.alignment(table.alignments[column])
        let text = InlineText(content: content)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .gridColumnAlignment(alignment)
        if wideColumns.contains(column) {
            text.frame(width: 300, alignment: Alignment(horizontal: alignment, vertical: .center))
        } else {
            text.fixedSize()
        }
    }

    private static func alignment(_ alignment: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        case .leading, .none: .leading
        }
    }

    /// Rough width in Latin characters; CJK and other wide scripts count double.
    private static func estimatedWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
    }
}

enum Clipboard {
    @MainActor
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
