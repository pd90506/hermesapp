import HermesKit
import SwiftUI

/// The composer's slash-command list, shown above the text area while
/// `composer.slashIsOpen` (`ComposerView`). Clicking a row accepts it.
///
/// Rows draw only from `composer.slashRows`, read once per update: a row never
/// indexes into the live list. When the list empties, SwiftUI lays out the rows
/// being removed one last time, and a row that looked up its neighbour in the
/// live list by its old index trapped (crash report `crash-slash-215700`).
///
/// The list is as tall as its rows, up to `maxListHeight`, then scrolls. A bare
/// `ScrollView` has no height of its own and took the whole cap even for one row.
struct SlashSuggestionList: View {
    let composer: ChatComposer
    /// After a row was accepted: the composer takes the keyboard back.
    var onAccept: () -> Void = {}

    /// About eight rows, then the list scrolls.
    private let maxListHeight: CGFloat = 220
    /// The rows' laid-out height, measured inside the scroll view.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if composer.slashIsOpen {
            list(composer.slashRows)
        } else if let notice = composer.slashNotice {
            // No rows: Desktop's "No matches." or why the lookup failed.
            Text(notice)
                .uiFont(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .accessibilityIdentifier("slash-notice")
        }
    }

    private func list(_ rows: [SlashRow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    if let header = row.header {
                        Text(header)
                            .uiFont(.caption, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Button {
                        composer.acceptSlashRow(id: row.id)
                        onAccept()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.suggestion.item.display ?? row.suggestion.item.text)
                                .uiFont(.body, design: .monospaced)
                            Text(row.suggestion.item.meta ?? "")
                                .uiFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(row.isSelected ? Color.accentColor.opacity(0.15) : .clear,
                                    in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("slash-option-\(row.suggestion.item.text)")
                    .accessibilityAddTraits(row.isSelected ? .isSelected : [])
                }
            }
            .padding(6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, maxListHeight))
        .accessibilityIdentifier("slash-popover")
    }
}
