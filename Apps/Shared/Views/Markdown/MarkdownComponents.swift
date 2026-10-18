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
    /// The code's size in points (Settings ▸ Appearance ▸ Code).
    var codeSize = TextSizes.defaults.code
    var messageSource: String? = nil
    var conversationSource: (() -> String)? = nil
    @Environment(\.markdownPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "")
                    .uiFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy code", systemImage: "doc.on.doc") { Clipboard.copy(code) }
                    .labelStyle(.iconOnly)
                    .hoverButtonStyle(.rounded, padding: 4)
                    .uiFont(.caption)
                    .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: codeSize, design: .monospaced))
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
        .background(palette.color(.codeBlockBackground, colorScheme), in: .rect(cornerRadius: 8))
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

/// Laid out as Desktop's transcript tables are (`components/assistant-ui/markdown-table.tsx`):
/// the full width of the column, a rounded border, a tinted header row and a 1 pt
/// rule between rows. The tints, rules and every other row's stripe take the Markdown
/// colours (Settings ▸ Markdown). Columns start at the widest cell's rendered width (bold
/// header, inline code, links and math included) and share the room left over in
/// proportion to it. Cells whose content is unusually long cap at 300 pt and wrap
/// when the column has no room for them; a grid wider than the column scrolls
/// sideways.
struct MarkdownTableGrid: View {
    let table: MarkdownTable
    var messageSource: String? = nil
    var conversationSource: (() -> String)? = nil
    @Environment(\.textSizes) private var sizes
    @Environment(\.markdownPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    /// Dynamic Type on iOS; 1 on macOS.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1
    private var bodySize: CGFloat { sizes.content * typeScale }
    /// The width the table may fill; 0 until the first layout reports it.
    @State private var available: CGFloat = 0

    static let cellPadding: CGFloat = 10
    static let cornerRadius: CGFloat = 6

    var body: some View {
        let layout = MarkdownTableLayout.layout(for: table, bodySize: bodySize)
        let widths = MarkdownTableLayout.fit(layout.widths, into: available - 2,
                                             padding: Self.cellPadding * 2)
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(layout.cells.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(layout.cells[row][column], width: widths[column], column: column, header: row == 0)
                                .background(background(row: row))
                                .overlay(alignment: .bottom) {
                                    if row < layout.cells.count - 1 { Rectangle().fill(border).frame(height: 1) }
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
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(border, lineWidth: 1) }
            .padding(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
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

    private var border: Color { palette.color(.tableBorder, colorScheme) }

    /// The header's tint, and a stripe on every other body row (the second, fourth, …).
    private func background(row: Int) -> Color {
        if row == 0 { return palette.color(.tableHeaderBackground, colorScheme) }
        return row.isMultiple(of: 2) ? palette.color(.tableStripe, colorScheme) : .clear
    }

    private func cell(_ selection: MarkdownSelection, width: CGFloat, column: Int, header: Bool) -> some View {
        let alignment: HorizontalAlignment = switch table.alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .leading, .none: .leading
        }
        // The cell's own text view takes the right-click, so it carries the
        // message's Copy Message / Copy Conversation like prose does.
        return SelectableMarkdownText(selection: selection, source: messageSource ?? selection.plainText,
                                      bodySize: bodySize, isReasoning: false,
                                      conversationSource: conversationSource, width: width, tableHeader: header)
            .frame(width: width, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(.horizontal, Self.cellPadding)
            .padding(.vertical, 6)
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
        /// Each column's widest cell on one line, uncapped.
        let widths: [CGFloat]
    }

    private struct Key: Hashable {
        let table: MarkdownTable
        let bodySize: CGFloat
    }

    private static var cache: [Key: Layout] = [:]

    /// The widest a column grows to before its cells wrap, when the grid has no room.
    static let wrapWidth: CGFloat = 300

    static func layout(for table: MarkdownTable, bodySize: CGFloat) -> Layout {
        let key = Key(table: table, bodySize: bodySize)
        if let layout = cache[key] { return layout }
        func selection(_ content: [MarkdownInline], header: Bool) -> MarkdownSelection {
            MarkdownSelection(document: MarkdownDocument(blocks: [.paragraph(header ? [.strong(content)] : content)]))
        }
        let cells = [table.header.map { selection($0, header: true) }]
            + table.rows.map { row in row.map { selection($0, header: false) } }
        let widths = table.header.indices.map { column in
            max(cells.map { width(of: $0[column], bodySize: bodySize) }.max() ?? 0, 24)
        }
        let layout = Layout(cells: cells, widths: widths)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = layout
        return layout
    }

    /// Column text widths for a grid `available` wide, each column adding `padding`:
    /// - everything fits on one line: the room left over is shared in proportion to
    ///   each column's width, so the grid is exactly `available` wide;
    /// - it fits with the long columns wrapped at `wrapWidth`: those columns get the
    ///   room there is, in proportion to what they lack;
    /// - otherwise the long columns wrap at `wrapWidth` and the grid scrolls.
    static func fit(_ natural: [CGFloat], into available: CGFloat, padding: CGFloat) -> [CGFloat] {
        let capped = natural.map { min($0, wrapWidth) }
        let pads = padding * CGFloat(natural.count)
        let room = (available - pads).rounded(.down)
        let full = natural.reduce(0, +)
        if room >= full, full > 0 {
            let extra = room - full
            return natural.map { ($0 + extra * $0 / full).rounded(.down) }
        }
        let wrapped = capped.reduce(0, +)
        if room > wrapped {
            let lacking = zip(natural, capped).map { $0 - $1 }
            let total = lacking.reduce(0, +)
            return zip(capped, lacking).map { ($0 + (room - wrapped) * $1 / total).rounded(.down) }
        }
        return capped
    }

    /// The cell's text on one line, as the cell's text view renders it.
    static func width(of selection: MarkdownSelection, bodySize: CGFloat) -> CGFloat {
        let text = MarkdownNativeText.make(selection, bodySize: bodySize).text
        let bounds = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin], context: nil)
        return ceil(bounds.width) + 1
    }
}
