import HermesKit
import SwiftUI

/// The composer's slash-command list, shown above the text area while
/// `composer.slashIsOpen` (`ComposerView`). Clicking a row accepts it.
///
/// Rows draw only from `composer.slashRows`, read once per update: a row never
/// indexes into the live list. When the list empties, SwiftUI lays out the rows
/// being removed one last time, and a row that looked up its neighbour in the
/// live list by its old index trapped (crash report `crash-slash-215700`).
struct SlashSuggestionList: View {
    let composer: ChatComposer
    /// After a row was accepted: the composer takes the keyboard back.
    var onAccept: () -> Void = {}

    var body: some View {
        if composer.slashIsOpen { list(composer.slashRows) }
    }

    private func list(_ rows: [SlashRow]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    if let header = row.header {
                        Text(header)
                            .font(.caption.weight(.semibold))
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
                                .font(.body.monospaced())
                            Text(row.suggestion.item.meta ?? "")
                                .font(.caption)
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
        }
        .frame(maxHeight: 220)
        .accessibilityIdentifier("slash-popover")
    }
}
