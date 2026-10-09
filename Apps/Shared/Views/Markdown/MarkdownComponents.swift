import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A fence owns its horizontal scroll and selection. The text has its natural
/// width, so long lines never wrap to the transcript column.
struct MarkdownCodeBlock: View {
    let language: String?
    let code: String
    var messageSource: String? = nil
    var conversationSource: (() -> String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy code", systemImage: "doc.on.doc") { Clipboard.copy(code) }
                    .labelStyle(.iconOnly)
                    .hoverButtonStyle(.rounded, padding: 4)
                    .font(.caption)
                    .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("markdownCodeScroll")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        #if os(macOS)
        .contextMenu { messageMenu }
        #endif
    }

    @ViewBuilder private var messageMenu: some View {
        if let messageSource {
            Button("Copy Message") { Clipboard.copy(messageSource) }
        }
        if let conversationSource {
            Button("Copy Conversation") { Clipboard.copy(conversationSource()) }
        }
    }
}

/// Grid columns take the widest cell's rendered width (bold header, inline
/// code, links and math included). Cells whose content is unusually long cap at
/// 300 pt and wrap, while the whole grid can scroll sideways. Lines are 1 pt
/// throughout: an outer border plus one divider between columns and rows.
struct MarkdownTableGrid: View {
    let table: MarkdownTable
    var messageSource: String? = nil
    var conversationSource: (() -> String)? = nil
    @ScaledMetric(relativeTo: .body) private var bodySize = MarkdownMetrics.bodySize

    var body: some View {
        let layout = MarkdownTableLayout.layout(for: table, bodySize: bodySize)
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(layout.cells.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(layout.cells[row][column], width: layout.widths[column], column: column)
                                .overlay(alignment: .trailing) {
                                    if column < table.header.count - 1 { Rectangle().fill(.quaternary).frame(width: 1) }
                                }
                                .overlay(alignment: .bottom) {
                                    if row < layout.cells.count - 1 { Rectangle().fill(.quaternary).frame(height: 1) }
                                }
                        }
                    }
                }
            }
            // Its ideal height, as the scroll view took. Offered the scroll view's
            // height instead, a Grid spreads a wrapped row's extra lines over all
            // its stretchy cells as well, outgrows the scroll view and loses its
            // last row and bottom border below it.
            .fixedSize(horizontal: false, vertical: true)
            .overlay { Rectangle().strokeBorder(.quaternary, lineWidth: 1) }
            .padding(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("markdownTableScroll")
        #if os(macOS)
        .contextMenu { messageMenu }
        #endif
    }

    @ViewBuilder private var messageMenu: some View {
        if let messageSource {
            Button("Copy Message") { Clipboard.copy(messageSource) }
        }
        if let conversationSource {
            Button("Copy Conversation") { Clipboard.copy(conversationSource()) }
        }
    }

    private func cell(_ selection: MarkdownSelection, width: CGFloat, column: Int) -> some View {
        let alignment: HorizontalAlignment = switch table.alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .leading, .none: .leading
        }
        // The cell's own text view takes the right-click, so it carries the
        // message's Copy Message / Copy Conversation like prose does.
        return SelectableMarkdownText(selection: selection, source: messageSource ?? selection.plainText,
                                      bodySize: bodySize, isReasoning: false,
                                      conversationSource: conversationSource, width: width)
            .frame(width: width, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .gridColumnAlignment(alignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// Each cell's selection (header cells bold) and each column's width, built
/// once per table and size: a streaming delta re-renders the grid, and a
/// finished table scrolls back into view, without re-measuring every cell.
@MainActor
enum MarkdownTableLayout {
    struct Layout {
        /// Row 0 is the header.
        let cells: [[MarkdownSelection]]
        let widths: [CGFloat]
    }

    private struct Key: Hashable {
        let table: MarkdownTable
        let bodySize: CGFloat
    }

    private static var cache: [Key: Layout] = [:]

    static func layout(for table: MarkdownTable, bodySize: CGFloat) -> Layout {
        let key = Key(table: table, bodySize: bodySize)
        if let layout = cache[key] { return layout }
        func selection(_ content: [MarkdownInline], header: Bool) -> MarkdownSelection {
            MarkdownSelection(document: MarkdownDocument(blocks: [.paragraph(header ? [.strong(content)] : content)]))
        }
        let cells = [table.header.map { selection($0, header: true) }]
            + table.rows.map { row in row.map { selection($0, header: false) } }
        let widths = table.header.indices.map { column in
            let widest = cells.map { width(of: $0[column], bodySize: bodySize) }.max() ?? 0
            return min(max(widest, 24), 300)
        }
        let layout = Layout(cells: cells, widths: widths)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = layout
        return layout
    }

    /// The cell's text on one line, as the cell's text view renders it.
    static func width(of selection: MarkdownSelection, bodySize: CGFloat) -> CGFloat {
        let text = MarkdownNativeText.make(selection, bodySize: bodySize).text
        let bounds = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin], context: nil)
        return ceil(bounds.width) + 1
    }
}
