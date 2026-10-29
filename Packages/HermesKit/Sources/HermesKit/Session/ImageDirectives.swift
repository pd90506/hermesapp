import Foundation

/// An image in a user message: sent from this device, or referenced by a stored row.
public struct TranscriptImage: Sendable, Hashable, Identifiable {
    /// The file name shown under a placeholder when the image cannot be loaded.
    public var name: String
    /// Where the image lives on the gateway: the `@image:` path of a stored row, or
    /// the path `image.attach_bytes` answered for an image sent from here. The app
    /// loads it with `GatewayConnection.imageData(path:profile:)`.
    public var path: String?
    /// The composer attachment it was sent from: its thumbnail is already on this
    /// device, so the bubble needs no download.
    public var localID: UUID?
    /// Its place among the message's images.
    public var position: Int

    public init(name: String, path: String? = nil, localID: UUID? = nil, position: Int = 0) {
        self.name = name
        self.path = path
        self.localID = localID
        self.position = position
    }

    /// Unique within a message, even when one path is attached twice, and the same
    /// for the live bubble and the stored row of one upload.
    public var id: String { "\(position):\(path ?? localID?.uuidString ?? name)" }

    /// An image referenced by a stored `@image:` path.
    public init(path: String, position: Int = 0) {
        self.init(name: (path as NSString).lastPathComponent, path: path, position: position)
    }

    /// The images of a stored message's `@image:` paths, in order.
    public static func stored(_ paths: [String]) -> [TranscriptImage] {
        paths.enumerated().map { TranscriptImage(path: $1, position: $0) }
    }

    /// Whether `path` names an image file by its extension: only those are read back
    /// (`GatewayMediaSource`).
    public static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// `/api/media`'s types (`hermes_cli/web_routers/files.py:48-51`) and what the
    /// composer sends (`ClipboardPolicy.imageFileExtensions`).
    static let imageExtensions: Set<String> = ClipboardPolicy.imageFileExtensions.union(["svg", "ico"])

    /// Images bigger than this are not decoded, even downsampled: a small, highly
    /// compressible file can expand to gigabytes (`ThumbnailStore.decode`).
    public static let maxDecodePixels = 100_000_000

    /// Whether an image of these pixel dimensions may be decoded; unknown ones may.
    public static func mayDecode(width: Int?, height: Int?) -> Bool {
        guard let width, let height, width > 0, height > 0 else { return true }
        return width.multipliedReportingOverflow(by: height).overflow == false && width * height <= maxDecodePixels
    }
}

/// The `@image:<path>` lines Hermes appends to a stored user message, one per
/// attached image, caption first (`tui_gateway/session_history.py:51-60`). A path
/// with whitespace or brackets is quoted with the first of `` ` ``, `"`, `'` it does
/// not contain (`agent/context_references.py:141-149`, Desktop's `formatRefValue`).
///
/// Only whole lines are read as directives; `@image:` inside a sentence stays text.
public enum ImageDirectives {
    public static let prefix = "@image:"

    /// The caption (every other line, trimmed at both ends) and the image paths, in order.
    /// A row that carries Hermes's model-only image hints instead (`ImageHints`) reads
    /// the same way.
    public static func split(_ text: String) -> (caption: String, paths: [String]) {
        let hinted = ImageHints.splitLeading(text)
        if !hinted.paths.isEmpty {
            let rest = split(hinted.text)
            return (rest.caption, hinted.paths + rest.paths)
        }
        guard text.contains(prefix) else { return (text, []) }
        var caption: [Substring] = []
        var paths: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = path(in: line) {
                paths.append(path)
            } else {
                caption.append(line)
            }
        }
        guard !paths.isEmpty else { return (text, []) }
        // A model that reads images itself gets them as parts, which the stored row
        // flattens to a `[screenshot]` line each after the text (`session_history.py:134-138`;
        // seen in the VM, 2026-10-29): the images already show, so those lines go.
        while let last = caption.last?.trimmingCharacters(in: .whitespaces),
            last.isEmpty || InjectedContext.placeholders.contains(last)
        {
            caption.removeLast()
        }
        return (caption.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    /// The path of a line that is exactly one `@image:` directive.
    static func path(in line: Substring) -> String? {
        value(in: line, prefix: prefix)
    }

    /// The value of a line that is exactly one `<prefix><value>` reference.
    static func value(in line: Substring, prefix: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let value = trimmed.dropFirst(prefix.count)
        guard let first = value.first else { return nil }
        if "`\"'".contains(first) {
            guard value.count >= 2, value.last == first else { return nil }
            let inner = value.dropFirst().dropLast()
            return inner.isEmpty || inner.contains(first) ? nil : String(inner)
        }
        return value.contains(where: \.isWhitespace) ? nil : String(value)
    }
}

/// The text Hermes gives the model for each attached image when the model reads images
/// with a tool (`tui_gateway/session_history.py:29-48`), in front of the typed text:
///
///     [The user attached an image: upload_0lufsdyf.png]
///     [Examine it with the vision_analyze tool using image_url: /home/u/.hermes/images/upload_0lufsdyf.png]
///
/// Hermes stores `@image:` lines instead (:51-60), but a stored row with two images
/// came back with these hints (the user, 2026-10-29), so the bubble showed them as
/// text. Only the leading run is read, as the hints are always first. With no typed
/// text Hermes adds "What do you see in this image?", which is not the user's.
public enum ImageHints {
    static let attached = "[The user attached an image: "
    static let examine = "[Examine it with the vision_analyze tool using image_url: "
    static let defaultQuestion = "What do you see in this image?"

    /// The text after the hints, trimmed, and the hinted image paths, in order.
    public static func splitLeading(_ text: String) -> (text: String, paths: [String]) {
        guard text.hasPrefix(attached) else { return (text, []) }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var paths: [String] = []
        while let first = lines.first, first.hasPrefix(attached), first.hasSuffix("]"),
              let second = lines.dropFirst().first, second.hasPrefix(examine), second.hasSuffix("]")
        {
            let path = second.dropFirst(examine.count).dropLast()
            guard !path.isEmpty else { break }
            paths.append(String(path))
            lines = lines.dropFirst(2)
            while lines.first?.isEmpty == true { lines = lines.dropFirst() }
        }
        guard !paths.isEmpty else { return (text, []) }
        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest == defaultQuestion ? "" : rest, paths)
    }
}

/// The `@file:` / `@folder:` lines a prompt with attached files starts with: the
/// composer sends one per file (`file.attach`'s `ref_text`), then a blank line and
/// the typed text (`ChatSession.send`). Like Desktop's `splitLeadingAttachmentRefs`
/// (`apps/desktop/src/components/assistant-ui/reference-kinds.ts:177-197`), only the
/// leading run is lifted off a stored row; a reference typed mid-prose stays text.
public enum AttachmentRefs {
    static let prefixes = ["@file:", "@folder:"]

    /// The text without its leading reference lines (trimmed when any were lifted),
    /// and their values (paths), in order.
    public static func splitLeading(_ text: String) -> (text: String, refs: [String]) {
        guard text.hasPrefix("@") else { return (text, []) }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var refs: [String] = []
        while let line = lines.first, let value = reference(in: line) {
            refs.append(value)
            lines = lines.dropFirst()
        }
        guard !refs.isEmpty else { return (text, []) }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), refs)
    }

    /// What a bubble shows for a reference: its file name.
    public static func displayName(_ ref: String) -> String {
        let name = (ref as NSString).lastPathComponent
        return name.isEmpty ? ref : name
    }

    /// Desktop tests the line without its trailing whitespace only: it must start
    /// with the reference.
    private static func reference(in line: Substring) -> String? {
        guard line.first == "@" else { return nil }
        return prefixes.lazy.compactMap { ImageDirectives.value(in: line, prefix: $0) }.first
    }
}
