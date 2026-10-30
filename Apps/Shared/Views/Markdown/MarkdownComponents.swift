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
/// proportion to it. When the column has no room for them, long cells wrap, down to
/// 10 em wide (`wrapWidth`), so a table first fits the column with more lines per
/// cell, as a web page's table does (the user, 2026-10-30). A grid that would still scroll reaches past the
/// column into the window's spare width (`tableReach`), centered on the column, only
/// as far as it needs to stop scrolling; once the window itself is too narrow, it
/// scrolls sideways.
struct MarkdownTableGrid: View {
    let table: MarkdownTable
    var messageSource: String? = nil
    var conversationSource: (() -> String)? = nil
    @Environment(\.textSizes) private var sizes
    @Environment(\.markdownPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tableReach) private var reach
    /// Dynamic Type on iOS; 1 on macOS.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1
    private var bodySize: CGFloat { sizes.content * typeScale }
    /// The width the table fills, its reach past the column included; 0 until the
    /// first layout reports it.
    @State private var available: CGFloat = 0

    static let cellPadding: CGFloat = 10
    static let cornerRadius: CGFloat = 6

    var body: some View {
        let layout = MarkdownTableLayout.layout(for: table, bodySize: bodySize)
        let wrap = MarkdownTableLayout.wrapWidth(bodySize: bodySize)
        let widths = MarkdownTableLayout.fit(layout.widths, into: available - 2,
                                             padding: Self.cellPadding * 2, wrapWidth: wrap)
        // The width where it stops scrolling, its long cells wrapped: it reaches no further
        // to put them on one line (the user, 2026-10-30).
        let needed = layout.widths.map { min($0, wrap) }.reduce(0, +)
            + Self.cellPadding * 2 * CGFloat(layout.widths.count) + 2
        TableReachLayout(needed: needed.rounded(.up), reach: reach) {
            grid(layout, widths: widths)
        }
        .accessibilityIdentifier("markdownTableScroll")
        #if os(macOS)
        .contextMenu { messageMenu }
        #endif
    }

    private func grid(_ layout: MarkdownTableLayout.Layout, widths: [CGFloat]) -> some View {
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

/// Lays out a table as wide as the column offers, or, when it `needs` more to stop
/// scrolling, wider by up to `reach` on each side, centered on the column (the user,
/// 2026-10-30). Its footprint stays the column's width, so the text around it does
/// not move.
struct TableReachLayout: Layout {
    let needed: CGFloat
    let reach: CGFloat

    /// The table's width, and how far its leading edge moves left, in a column `width` wide.
    func extent(in width: CGFloat) -> (width: CGFloat, lead: CGFloat) {
        let over = max(0, min(needed, width + 2 * reach) - width)
        return (width + over, over / 2)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let table = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            return table.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        }
        let height = table.sizeThatFits(ProposedViewSize(width: extent(in: width).width, height: nil)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let table = subviews.first else { return }
        let extent = extent(in: bounds.width)
        table.place(at: CGPoint(x: bounds.minX - extent.lead, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: extent.width, height: bounds.height))
    }
}

extension EnvironmentValues {
    /// How far a table may reach past each side of the text's column, into the
    /// window's spare width (`ChatView`). 0 outside the chat, and on iOS.
    @Entry var tableReach: CGFloat = 0
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

    /// The narrowest a long column wraps to before the grid reaches past the column or
    /// scrolls: 10 em, about 10 CJK characters or 20 Latin ones a line. It was 300 pt,
    /// and a table of three long columns, which fits the column wrapped narrower, grew
    /// past it (the user, 2026-10-30).
    static func wrapWidth(bodySize: CGFloat) -> CGFloat { (bodySize * 10).rounded() }

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
    static func fit(_ natural: [CGFloat], into available: CGFloat, padding: CGFloat,
                    wrapWidth: CGFloat) -> [CGFloat] {
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
