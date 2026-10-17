import HermesKit
import SwiftUI

/// An attached image or file in the composer: thumbnail (or the file's icon), name,
/// detail line and remove control. On macOS ✕ shows on hover, as in Hermes Desktop;
/// iOS has no hover, so it is always there.
struct AttachmentCardView: View {
    let name: String
    let detail: String
    /// An image's thumbnail; files show `fileIcon` instead.
    let thumbnail: CGImage?
    /// Set for a file card: its icon (`FileKind.systemImage`).
    var fileIcon: String?
    var isSending: Bool
    let onRemove: () -> Void

    init(attachment: ComposerAttachment, thumbnail: CGImage?, isSending: Bool, onRemove: @escaping () -> Void) {
        self.name = attachment.filename
        self.detail = attachment.detail
        self.thumbnail = thumbnail
        self.isSending = isSending
        self.onRemove = onRemove
    }

    init(file: ComposerFile, isSending: Bool, onRemove: @escaping () -> Void) {
        self.name = file.name
        self.detail = file.detail
        self.thumbnail = nil
        self.fileIcon = FileKind(filename: file.name).systemImage
        self.isSending = isSending
        self.onRemove = onRemove
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .uiFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .uiFont(.caption2)
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
                    Label("Remove \(name)", systemImage: "xmark")
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
        .accessibilityLabel("\(fileIcon == nil ? "Image" : "File") \(name), \(detail)")
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
                Image(systemName: fileIcon ?? "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(.rect(cornerRadius: 3))
    }
}

/// A file still uploading (`ChatComposer.uploadingFileNames`): the card it will
/// become, with a spinner in place of its icon.
struct UploadingCardView: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .uiFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Uploading…")
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .frame(width: 200, height: 40)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Uploading \(name)")
    }
}
