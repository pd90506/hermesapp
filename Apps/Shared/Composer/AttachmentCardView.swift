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
    /// An image still uploading to the session's queue (`ChatComposer.uploadingImageIDs`):
    /// a spinning ring over its thumbnail, as Claude Code shows one.
    var isUploading = false
    /// Why an image's early upload failed; the send uploads it again.
    var uploadFailure: String?
    let onRemove: () -> Void

    init(attachment: ComposerAttachment, thumbnail: CGImage?, isSending: Bool, isUploading: Bool = false,
         uploadFailure: String? = nil, onRemove: @escaping () -> Void) {
        self.name = attachment.filename
        self.detail = uploadFailure == nil ? attachment.detail : "Upload failed. Sending tries again."
        self.thumbnail = thumbnail
        self.isSending = isSending
        self.isUploading = isUploading
        self.uploadFailure = uploadFailure
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

    /// The card's size and shape: on iOS larger and rounder, as the Claude app's
    /// attachments in its composer card.
    struct Metrics {
        var size: CGSize
        var cornerRadius: CGFloat
        var thumbnail: CGFloat
        var thumbnailRadius: CGFloat
        /// The ✕'s circle.
        var removeSize: CGFloat

        static var current: Metrics {
            #if os(macOS)
            Metrics(size: CGSize(width: 200, height: 40), cornerRadius: 4, thumbnail: 28, thumbnailRadius: 3,
                    removeSize: 18)
            #else
            Metrics(size: CGSize(width: 210, height: 56), cornerRadius: 14, thumbnail: 40, thumbnailRadius: 9,
                    removeSize: 24)
            #endif
        }
    }

    /// The space between cards in the composer.
    static var spacing: CGFloat {
        #if os(macOS)
        6
        #else
        8
        #endif
    }

    private var metrics: Metrics { .current }

    var body: some View {
        #if os(iOS)
        if fileIcon == nil {
            imageTile
        } else {
            card
        }
        #else
        card
        #endif
    }

    #if os(iOS)
    /// On iOS an image is a square of its own picture, ✕ at its corner, as the Claude
    /// app's composer shows one.
    private var imageTile: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return thumbnailView(size: Self.tileSize, cornerRadius: 16)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Label("Remove \(name)", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white, in: .circle)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        // A touch target larger than the circle.
                        .padding(6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
            .opacity(isSending ? 0.6 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Image \(name), \(isUploading ? "uploading" : detail)")
            .accessibilityAction(named: "Remove") { if !isSending { onRemove() } }
    }

    /// An image tile's side.
    static let tileSize: CGFloat = 84
    #endif

    private var card: some View {
        HStack(spacing: 8) {
            thumbnailView(size: metrics.thumbnail, cornerRadius: metrics.thumbnailRadius)
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
        .padding(.leading, (metrics.size.height - metrics.thumbnail) / 2)
        .padding(.trailing, metrics.removeSize + 4)
        .frame(width: metrics.size.width, height: metrics.size.height)
        .attachmentCardBackground(metrics)
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
                .frame(width: metrics.removeSize, height: metrics.removeSize)
                .background(.background.opacity(0.8), in: .circle)
                    .padding(.trailing, 4)
                    .disabled(isSending)
                    .help("Remove")
            }
        }
        .onHover { isHovering = $0 }
        .opacity(isSending ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fileIcon == nil ? "Image" : "File") \(name), \(isUploading ? "uploading" : detail)")
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

    private func thumbnailView(size: CGFloat, cornerRadius: CGFloat) -> some View {
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
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if isUploading {
                UploadRing(size: min(size * 0.6, 28))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.35), in: .rect(cornerRadius: cornerRadius, style: .continuous))
            } else if uploadFailure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: size * 0.4))
                    .help(uploadFailure ?? "")
            }
        }
    }
}

/// A spinning ring over an image that is uploading. `image.attach_bytes` sends the
/// image as one message and reports nothing until it is queued, so the ring shows
/// that it is under way, not how far.
private struct UploadRing: View {
    let size: CGFloat
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
        }
        .frame(width: size, height: size)
        .onAppear { turning = true }
        .accessibilityHidden(true)
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
                .frame(width: metrics.thumbnail, height: metrics.thumbnail)
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
        .padding(.leading, (metrics.size.height - metrics.thumbnail) / 2)
        .frame(width: metrics.size.width, height: metrics.size.height)
        .attachmentCardBackground(metrics)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Uploading \(name)")
    }

    private var metrics: AttachmentCardView.Metrics { .current }
}

private extension View {
    /// A card's fill and outline: on the Mac a faint box, on iOS a rounded tile on the
    /// composer's glass.
    func attachmentCardBackground(_ metrics: AttachmentCardView.Metrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        #if os(macOS)
        return background(.quaternary.opacity(0.5), in: shape)
            .overlay { shape.strokeBorder(.separator, lineWidth: 1) }
        #else
        return background(Color.primary.opacity(0.06), in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
        #endif
    }
}
