import HermesKit
import SwiftUI

/// An attached image in the composer: thumbnail, name, detail line and remove
/// control. On macOS ✕ shows on hover, as in Hermes Desktop; iOS has no hover,
/// so it is always there.
struct AttachmentCardView: View {
    let attachment: ComposerAttachment
    let thumbnail: CGImage?
    var isSending: Bool
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 22)
        .frame(width: 200, height: 40)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1)
        }
        .overlay(alignment: .trailing) {
            if showsRemove {
                Button(action: onRemove) {
                    Label("Remove \(attachment.filename)", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12, height: 12)
                }
                .hoverButtonStyle(.circle, padding: 3)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.background.opacity(0.8), in: .circle)
                    .padding(.trailing, 4)
                    .disabled(isSending)
                    .help("Remove")
            }
        }
        .onHover { isHovering = $0 }
        .opacity(isSending ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image \(attachment.filename), \(attachment.detail)")
        // Like the ✕, unavailable while the card is being sent.
        .accessibilityAction(named: "Remove") { if !isSending { onRemove() } }
    }

    private var showsRemove: Bool {
        #if os(macOS)
        isHovering
        #else
        true
        #endif
    }

    @ViewBuilder private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(.rect(cornerRadius: 3))
    }
}
