import CoreGraphics
import Foundation
import HermesKit
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where an image or file to attach comes from.
enum AttachmentSource: Sendable {
    case file(URL)
    case data(Data, filename: String)

    var filename: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .data(_, let filename): filename
        }
    }

    /// Whether to attach it as an image (re-encoded if needed, `ImageLoader`) rather
    /// than as a file (`file.attach`), by its extension. Desktop likewise sends an
    /// attachment of kind `image` with `image.attach_bytes` and anything else with
    /// `file.attach` (`use-prompt-actions/index.ts:139-160`).
    var isImage: Bool {
        ClipboardPolicy.imageFileExtensions.contains((filename as NSString).pathExtension.lowercased())
    }
}

/// A composer card's payload plus its thumbnail.
struct LoadedImage: @unchecked Sendable {
    // @unchecked: CGImage is an immutable CoreFoundation object, safe to hand between threads.
    var attachment: ComposerAttachment
    var thumbnail: CGImage?
}

/// Reads images and turns them into something `image.attach_bytes` takes:
/// PNG/JPEG/GIF/WebP pass through; anything else (HEIC photos, TIFF from the
/// pasteboard) is re-encoded, and an image over the gateway's 25 MB cap is
/// scaled down (`ImageAttachmentPolicy`).
enum ImageLoader {
    enum Failure: LocalizedError {
        case unreadable(String, String)
        case notAnImage(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name, let reason): "Couldn't read \(name): \(reason)"
            case .notAnImage(let name): "\(name) is not an image."
            case .tooLarge(let name): "\(name) is too large to attach, even scaled down."
            }
        }
    }

    /// Longest side of the thumbnail, in pixels: the composer card's 28 pt square and
    /// the sent bubble's 160 pt card (`TranscriptImageCard`) share it.
    nonisolated static let thumbnailPixels = 480

    /// Decodes and, if needed, re-encodes. `@concurrent`: always off the main
    /// actor, whatever the module's default isolation.
    @concurrent
    nonisolated static func load(_ source: AttachmentSource) async throws -> LoadedImage {
        let (data, filename, origin) = try read(source)
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 else {
            throw Failure.notAnImage(filename)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] ?? [:]
        var width = properties[kCGImagePropertyPixelWidth] as? Int
        var height = properties[kCGImagePropertyPixelHeight] as? Int
        let actualExtension = (CGImageSourceGetType(image) as String?)
            .flatMap { UTType($0)?.preferredFilenameExtension }
            .map { $0 == "jpeg" ? "jpg" : $0 } ?? ""

        var payload = data
        var name = filename
        if ImageAttachmentPolicy.passthroughExtensions.contains(actualExtension), data.count <= ImageAttachmentPolicy.maxBytes {
            // The gateway trusts the filename's extension; make it tell the truth.
            if !sameType(ImageAttachmentPolicy.fileExtension(name), actualExtension) {
                name = ImageAttachmentPolicy.filename(name, withExtension: actualExtension)
            }
        } else {
            // First encode within the cap wins (`ImageAttachmentPolicy.encodeAttempts`).
            let attempts = ImageAttachmentPolicy.encodeAttempts(
                sourceBytes: data.count, pixelWidth: width, pixelHeight: height,
                hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false)
            var fitted: (data: Data, width: Int, height: Int, format: ImageAttachmentPolicy.EncodedFormat)?
            var decoded = false
            for attempt in attempts {
                guard let encoded = reencode(image, attempt) else { continue }
                decoded = true
                if encoded.data.count <= ImageAttachmentPolicy.maxBytes {
                    fitted = (encoded.data, encoded.width, encoded.height, attempt.format)
                    break
                }
            }
            guard decoded else { throw Failure.notAnImage(filename) }
            guard let fitted else { throw Failure.tooLarge(filename) }
            payload = fitted.data
            width = fitted.width
            height = fitted.height
            name = ImageAttachmentPolicy.filename(name, withExtension: fitted.format.fileExtension)
        }

        let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ] as CFDictionary)
        let attachment = ComposerAttachment(filename: name, data: payload, pixelWidth: width, pixelHeight: height,
                                            source: origin)
        return LoadedImage(attachment: attachment, thumbnail: thumbnail)
    }

    private static func sameType(_ a: String, _ b: String) -> Bool {
        let jpeg: Set<String> = ["jpg", "jpeg"]
        return a == b || (jpeg.contains(a) && jpeg.contains(b))
    }

    /// Bytes, the name to show, and (macOS) the folder it came from.
    private static func read(_ source: AttachmentSource) throws -> (Data, String, String?) {
        switch source {
        case .data(let data, let filename):
            return (data, filename, nil)
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                #if os(macOS)
                let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                return (data, url.lastPathComponent, folder)
                #else
                // iOS container paths mean nothing to the user; show size instead.
                return (data, url.lastPathComponent, nil)
                #endif
            } catch {
                throw Failure.unreadable(url.lastPathComponent, error.localizedDescription)
            }
        }
    }

    /// A native-size or scaled-down re-encode that applies the EXIF orientation.
    private static func reencode(_ image: CGImageSource, _ attempt: ImageAttachmentPolicy.EncodeAttempt)
        -> (data: Data, width: Int, height: Int)?
    {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        // Without a maximum, ImageIO keeps the image's own size.
        if let maxPixels = attempt.maxPixels { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        let type = (attempt.format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, cgImage.width, cgImage.height)
    }

    // MARK: - Pasteboard and drops

    #if os(macOS)
    /// What a pasteboard (a paste or a drag) holds, for `ClipboardPolicy`.
    @MainActor
    static func contents(of pasteboard: NSPasteboard) -> ClipboardPolicy.Contents {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return ClipboardPolicy.Contents(types: pasteboard.types?.map(\.rawValue) ?? [],
                                        string: pasteboard.string(forType: .string), fileURLs: urls ?? [])
    }

    /// The images and files a pasteboard holds, or none when it should paste as
    /// text (`ClipboardPolicy.decide`).
    @MainActor
    static func sources(from pasteboard: NSPasteboard) -> [AttachmentSource] {
        switch ClipboardPolicy.decide(contents(of: pasteboard)) {
        case .text, .fileItems:
            return []
        case .files(let urls):
            return urls.map(AttachmentSource.file)
        case .imageData(let type):
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else { return [] }
            let ext = UTType(type)?.preferredFilenameExtension ?? "png"
            return [.data(data, filename: "Pasted Image.\(ext)")]
        }
    }
    /// Whether a drag pasteboard's files are the ones a drop's providers carry: as many,
    /// each of a type some provider has. The shared drag pasteboard keeps the last drag
    /// that used it, which need not be this one.
    static func sources(_ sources: [AttachmentSource], match providers: [NSItemProvider]) -> Bool {
        guard !sources.isEmpty, sources.count == providers.count else { return false }
        let types = providers.flatMap(\.registeredContentTypes)
        return sources.allSatisfy { source in
            guard case .file(let url) = source else { return false }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension) ?? .data
            return types.contains { type.conforms(to: $0) || $0 == .fileURL }
        }
    }
    #else
    /// The general pasteboard's image and file providers, or none when it should
    /// paste as text (`ClipboardPolicy.decide`). Reads the pasteboard's contents: call
    /// it only once the user chose Paste, or iOS shows its paste-permission alert.
    @MainActor
    static func pastedProviders() -> [NSItemProvider] {
        let pasteboard = UIPasteboard.general
        let fileItems = pasteboard.types.contains { UTType($0).map(isFileContent) ?? false }
        guard pasteboard.hasImages || pasteboard.hasURLs || fileItems else { return [] }
        let contents = ClipboardPolicy.Contents(types: pasteboard.types, string: pasteboard.string,
                                                fileURLs: (pasteboard.urls ?? []).filter(\.isFileURL),
                                                hasFileItems: fileItems)
        if case .text = ClipboardPolicy.decide(contents) { return [] }
        return pasteboard.itemProviders.filter { isAttachable($0) }
    }
    #endif

    /// A type that is a file's contents rather than text, an image, a link or rich
    /// text: a PDF, an archive, a document. Such an item is attached as a file.
    nonisolated static func isFileContent(_ type: UTType) -> Bool {
        type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .image)
            && !type.conforms(to: .url) && !type.conforms(to: .rtf) && !type.conforms(to: .rtfd)
            && !type.conforms(to: .html) && !type.conforms(to: .flatRTFD)
    }

    /// Whether a dropped or pasted provider carries something to attach. `fileDrop`:
    /// see `fileType(of:fileDrop:)`.
    nonisolated static func isAttachable(_ provider: NSItemProvider, fileDrop: Bool = false) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.registeredContentTypes.contains { $0.conforms(to: .image) }
            || fileType(of: provider, fileDrop: fileDrop) != nil
    }

    /// The type of the file a provider carries without a file URL: a file's contents
    /// (`isFileContent`), or text that has a file name, such as a Markdown file dragged
    /// from Files. Text without a name is a snippet, which stays text, unless it is
    /// `fileDrop`: a file dropped on the Mac, which SwiftUI hands over without its name
    /// (its file representation has it).
    nonisolated static func fileType(of provider: NSItemProvider, fileDrop: Bool = false) -> UTType? {
        let types = provider.registeredContentTypes
        if let type = types.first(where: isFileContent) { return type }
        guard fileDrop || provider.suggestedName?.isEmpty == false else { return nil }
        return types.first { $0.conforms(to: .text) }
    }

    /// Sources from dropped (or iOS-pasted) item providers: a file URL when the
    /// provider has one, else the image data, else a copy of the file it carries.
    @MainActor
    static func sources(from providers: [NSItemProvider], fileDrop: Bool = false) async -> [AttachmentSource] {
        var sources: [AttachmentSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                let url = await loadFileURL(provider)
            {
                sources.append(.file(url))
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }),
                let data = await loadData(provider, type: type)
            {
                let base = provider.suggestedName ?? "Image"
                let ext = type.preferredFilenameExtension ?? "png"
                sources.append(.data(data, filename: ImageAttachmentPolicy.filename(base, withExtension: ext)))
            } else if let type = fileType(of: provider, fileDrop: fileDrop),
                let copy = await loadFileCopy(provider, type: type)
            {
                sources.append(.file(copy))
            }
        }
        return sources
    }

    /// The provider's file, copied to a temporary folder: the system deletes its
    /// own copy as soon as the load's handler returns.
    @MainActor
    private static func loadFileCopy(_ provider: NSItemProvider, type: UTType) async -> URL? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { return continuation.resume(returning: nil) }
                var name = suggested ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                    name += ".\(ext)"
                }
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Attachments", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let copy = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    @MainActor
    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
    }
}
