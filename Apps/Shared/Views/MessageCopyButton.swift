import SwiftUI

/// Copies one message's source. Always shown on iOS; on macOS it appears while
/// the pointer is over the message.
struct MessageCopyButton: View {
    var isVisible = true
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        Button("Copy Message", systemImage: "doc.on.doc", action: action)
            .labelStyle(.iconOnly)
            .hoverButtonStyle(.rounded, padding: 4)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityLabel("Copy Message")
            .help("Copy Message")
        #else
        Button("Copy Message", systemImage: "doc.on.doc", action: action)
            .labelStyle(.iconOnly)
            .font(.caption)
            .accessibilityLabel("Copy Message")
        #endif
    }
}

/// Where the macOS hover-only copy button goes. Neither placement adds height to
/// the row, and neither puts the button over the message's text.
enum MessageCopyPlacement {
    /// In a gutter reserved along the row's trailing edge, at `alignment`: for
    /// rows whose text can run the full width (replies, tool and system rows).
    case trailingGutter(VerticalAlignment)
    /// Hanging just past the leading edge, in the empty space beside a trailing
    /// user bubble.
    case leadingOutside
}

extension MessageCopyButton {
    /// Width kept clear for the button beside full-width rows: the button is
    /// about 24 pt wide, plus a small gap from the text.
    static let gutterWidth: CGFloat = 30
}

extension View {
    /// On macOS, places the hover-only copy button beside the message instead of
    /// stacking it below, so a hidden button adds no height, and outside the
    /// message's text, so a visible one never covers or intercepts it.
    /// On iOS the row places a visible `MessageCopyButton` itself.
    @ViewBuilder
    func messageCopyAccessory(isHovering: Bool, placement: MessageCopyPlacement,
                              action: @escaping () -> Void) -> some View {
        #if os(macOS)
        switch placement {
        case .trailingGutter(let vertical):
            padding(.trailing, MessageCopyButton.gutterWidth)
                .overlay(alignment: Alignment(horizontal: .trailing, vertical: vertical)) {
                    MessageCopyButton(isVisible: isHovering, action: action)
                }
        case .leadingOutside:
            overlay(alignment: .bottomLeading) {
                MessageCopyButton(isVisible: isHovering, action: action)
                    .alignmentGuide(.leading) { $0[.trailing] + 4 }
            }
        }
        #else
        self
        #endif
    }
}
