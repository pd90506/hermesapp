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

/// Where an image to attach comes from.
enum ImageSource: Sendable {
    case file(URL)
    case data(Data, filename: String)
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
    nonisolated static func load(_ source: ImageSource) async throws -> LoadedImage {
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
    private static func read(_ source: ImageSource) throws -> (Data, String, String?) {
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

    /// The images a pasteboard holds, or none when it should paste as text
    /// (`ClipboardPolicy.decide`).
    @MainActor
    static func sources(from pasteboard: NSPasteboard) -> [ImageSource] {
        switch ClipboardPolicy.decide(contents(of: pasteboard)) {
        case .text:
            return []
        case .files(let urls):
            return urls.map(ImageSource.file)
        case .imageData(let type):
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else { return [] }
            let ext = UTType(type)?.preferredFilenameExtension ?? "png"
            return [.data(data, filename: "Pasted Image.\(ext)")]
        }
    }
    #else
    /// The general pasteboard's image providers, or none when it should paste as
    /// text (`ClipboardPolicy.decide`). Reads the pasteboard's contents: call it only
    /// once the user chose Paste, or iOS shows its paste-permission alert.
    @MainActor
    static func pastedImageProviders() -> [NSItemProvider] {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages || pasteboard.hasURLs else { return [] }
        let contents = ClipboardPolicy.Contents(types: pasteboard.types, string: pasteboard.string,
                                                fileURLs: (pasteboard.urls ?? []).filter(\.isFileURL))
        if case .text = ClipboardPolicy.decide(contents) { return [] }
        return pasteboard.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
    }
    #endif

    /// Image sources from dropped (or iOS-pasted) item providers: a file URL
    /// when the provider has one, else the image data.
    @MainActor
    static func sources(from providers: [NSItemProvider]) async -> [ImageSource] {
        var sources: [ImageSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                let url = await loadFileURL(provider), (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)
            {
                sources.append(.file(url))
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }),
                let data = await loadData(provider, type: type)
            {
                let base = provider.suggestedName ?? "Image"
                let ext = type.preferredFilenameExtension ?? "png"
                sources.append(.data(data, filename: ImageAttachmentPolicy.filename(base, withExtension: ext)))
            }
        }
        return sources
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
