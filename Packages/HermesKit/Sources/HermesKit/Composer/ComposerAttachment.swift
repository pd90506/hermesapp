import Foundation

/// An image waiting in the composer. The bytes stay on the device until the
/// prompt is sent; they are uploaded with `image.attach_bytes` right before
/// `prompt.submit`, like Desktop does for a remote gateway
/// (`apps/desktop/src/app/session/hooks/use-prompt-actions/index.ts:439-443`).
public struct ComposerAttachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// Sent as `filename`; its extension decides the stored type on the gateway.
    public var filename: String
    public var data: Data
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Where it came from, e.g. a file path; shown instead of the size line when set.
    public var source: String?

    public init(id: UUID = UUID(), filename: String, data: Data, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                source: String? = nil) {
        self.id = id
        self.filename = filename
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.source = source
    }

    /// The card's second line: the source path, else `1920×1080 · 2.4 MB`.
    public var detail: String {
        if let source, !source.isEmpty { return source }
        var parts: [String] = []
        if let pixelWidth, let pixelHeight { parts.append("\(pixelWidth)×\(pixelHeight)") }
        parts.append(Self.formatBytes(data.count))
        return parts.joined(separator: " · ")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// `512 bytes`, `14 KB`, `2.4 MB` (decimal units, like Finder).
    public static func formatBytes(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count) bytes"
        case ..<1_000_000: return "\(Int((Double(count) / 1000).rounded())) KB"
        default: return String(format: "%.1f MB", Double(count) / 1_000_000)
        }
    }
}

/// What the gateway accepts for `image.attach_bytes`, and what the app must
/// re-encode before attaching.
public enum ImageAttachmentPolicy {
    /// The gateway's cap; larger uploads fail with 4018 (`prompt_attachments.py:16,50-60`).
    public static let maxBytes = 25 * 1024 * 1024

    /// Formats sent unchanged. Hermes stores more (`bmp`, `tiff`, `svg`, `ico`,
    /// `hermes_cli/cli_terminal_input.py:33-36`) but not HEIC, and vision
    /// providers commonly read only these four. `[client choice]` Anything
    /// else (HEIC photos, TIFF screenshots) is re-encoded by the app first.
    public static let passthroughExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    public static func canSendUnchanged(filename: String) -> Bool {
        passthroughExtensions.contains(fileExtension(filename))
    }

    /// `IMG_0001.HEIC` → `IMG_0001.jpg` for a re-encoded copy.
    public static func filename(_ original: String, withExtension newExtension: String) -> String {
        let name = original.isEmpty ? "image" : original
        let ext = fileExtension(name)
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        return "\(stem.isEmpty ? "image" : stem).\(newExtension)"
    }

    /// Lower-cased, without the dot; empty when there is none.
    public static func fileExtension(_ filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return "" }
        let ext = filename[filename.index(after: dot)...]
        return ext.contains("/") ? "" : ext.lowercased()
    }

    /// Why an image cannot be attached, or `nil` when it can.
    public static func rejection(for attachment: ComposerAttachment) -> String? {
        if attachment.data.isEmpty { return "\(attachment.filename) is empty." }
        if attachment.data.count > maxBytes {
            return "\(attachment.filename) is too large (\(ComposerAttachment.formatBytes(attachment.data.count)); "
                + "the limit is \(maxBytes / 1024 / 1024) MB)."
        }
        if !canSendUnchanged(filename: attachment.filename) {
            return "\(attachment.filename) is not a PNG, JPEG, GIF or WebP image."
        }
        return nil
    }
}

extension ImageAttachmentPolicy {
    /// At most this many cards per message. `[client choice]`: every card holds
    /// its bytes in memory, and each upload briefly needs a few times that.
    public static let maxAttachments = 10

    /// Long side tried when the full-size encode is over `maxBytes`.
    public static let downscaleSides = [4096, 2048]

    public enum EncodedFormat: Sendable, Hashable {
        case png, jpeg

        public var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    /// One encode to try. `maxPixels == nil` keeps the native size.
    public struct EncodeAttempt: Sendable, Hashable {
        public var maxPixels: Int?
        public var format: EncodedFormat

        public init(maxPixels: Int?, format: EncodedFormat) {
            self.maxPixels = maxPixels
            self.format = format
        }
    }

    /// The encodes to try, in order, for an image that cannot be sent as it is;
    /// the app keeps the first output within `maxBytes`.
    /// - Native size first, unless the source alone is over the cap.
    /// - Then 4096 and 2048 px on the long side, each in the preferred format
    ///   (PNG keeps alpha) and then as JPEG.
    /// - Unknown dimensions never produce a 1-px image: they start at native
    ///   size and fall back to the fixed sides.
    public static func encodeAttempts(sourceBytes: Int, pixelWidth: Int?, pixelHeight: Int?,
                                      hasAlpha: Bool) -> [EncodeAttempt]
    {
        let preferred: EncodedFormat = hasAlpha ? .png : .jpeg
        let formats: [EncodedFormat] = hasAlpha ? [.png, .jpeg] : [.jpeg]
        let longest = max(pixelWidth ?? 0, pixelHeight ?? 0)
        let known = longest > 0
        var attempts: [EncodeAttempt] = []
        if sourceBytes <= maxBytes {
            attempts.append(EncodeAttempt(maxPixels: nil, format: preferred))
        }
        for side in downscaleSides where !known || side < longest {
            attempts += formats.map { EncodeAttempt(maxPixels: side, format: $0) }
        }
        // A small image whose source is over the cap (e.g. a long animated GIF):
        // a single JPEG frame at native size.
        let lastResort = EncodeAttempt(maxPixels: nil, format: .jpeg)
        if attempts.isEmpty || (known && longest <= downscaleSides.last! && !attempts.contains(lastResort)) {
            attempts.append(lastResort)
        }
        return attempts
    }
}

/// Why a composer action failed before anything reached the gateway.
public enum ComposerError: Error, Sendable, Equatable {
    /// An upload failed; earlier uploads of the same send were detached again.
    case attachmentFailed(filename: String, reason: String)
    /// No connection: nothing was uploaded or submitted.
    case notConnected
    /// Not `none` or a known level; never sent (see `ReasoningEffort.isSendable`).
    case unsupportedEffort(String)
    /// Images an earlier failed send left queued could not be detached, so this
    /// send did not go out: they would have ridden with it.
    case strandedImages

    public var message: String {
        switch self {
        case .attachmentFailed(let filename, let reason): "Couldn't attach \(filename): \(reason)"
        case .notConnected: "Not connected to Hermes. Nothing was sent; try again once it reconnects."
        case .unsupportedEffort(let value): "\"\(value)\" is not a reasoning effort level."
        case .strandedImages:
            "Images from an earlier failed send are still queued on Hermes and couldn't be removed, "
                + "so nothing was sent (they would have gone with it). Try again."
        }
    }
}
