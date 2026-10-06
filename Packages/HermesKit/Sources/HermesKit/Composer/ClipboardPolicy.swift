import Foundation

/// What a paste (or a drop) into the composer does: attach images, or insert text.
///
/// Like Hermes Desktop, an image on the clipboard is attached
/// (`apps/desktop/src/app/chat/composer/index.tsx:580-611`). Common image clipboards
/// carry a string or HTML beside the picture, so a string alone never makes it text:
/// - a screenshot to the clipboard (⌃⇧⌘4) or Preview's Copy: image data only;
/// - Safari's or Chrome's Copy Image: image data with the image's URL, or HTML;
/// - Finder's Copy of a file: its file URL, with its name as a string and its icon as TIFF;
/// - Slack and similar: image data with a link.
/// What stays text: a clipboard whose string is real text (a spreadsheet range or a
/// rich-text selection also carries a picture of itself), and a Finder copy of files
/// none of which is an image (their icon is not what the user meant).
public enum ClipboardPolicy {
    /// A pasteboard, as read by the app (`NSPasteboard` / `UIPasteboard`).
    public struct Contents: Sendable, Hashable {
        /// Uniform type identifiers on the pasteboard.
        public var types: [String]
        /// Its plain-text string, if it has one.
        public var string: String?
        /// Its file URLs (a Finder copy, or a drag of files).
        public var fileURLs: [URL]

        public init(types: [String], string: String? = nil, fileURLs: [URL] = []) {
            self.types = types
            self.string = string
            self.fileURLs = fileURLs
        }
    }

    public enum Decision: Sendable, Hashable {
        /// Insert as text: what the text view does on its own.
        case text
        /// Attach these image files.
        case files([URL])
        /// Attach the pasteboard's image data of this type.
        case imageData(type: String)
    }

    /// Image data types, preferred first: lossless and common before the rest.
    public static let imageDataTypes = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif",
        "com.compuserve.gif", "org.webmproject.webp", "com.microsoft.bmp",
    ]

    /// File extensions read as images; anything the app can convert (`ImageAttachmentPolicy`).
    public static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
    ]

    public static func decide(_ contents: Contents) -> Decision {
        if !contents.fileURLs.isEmpty {
            let images = contents.fileURLs.filter { imageFileExtensions.contains($0.pathExtension.lowercased()) }
            return images.isEmpty ? .text : .files(images)
        }
        guard let type = imageDataTypes.first(where: contents.types.contains) else { return .text }
        return isIncidental(contents.string) ? .imageData(type: type) : .text
    }

    /// A string that comes along with a copied image rather than being what was
    /// copied: none, blank, or one line that is a link or an image file name.
    static func isIncidental(_ string: String?) -> Bool {
        let text = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        guard !text.contains(where: \.isNewline) else { return false }
        // Only link schemes: `TODO:fix` or `key:value` in a copied cell is text.
        if text.range(of: #"^(?i:https?|file|data):\S+$"#, options: .regularExpression) != nil { return true }
        let ext = (text as NSString).pathExtension.lowercased()
        return imageFileExtensions.contains(ext)
    }
}
