import Foundation

/// What a file is, by its extension: enough to pick an icon and decide whether
/// the app can show it inline. The apps preview every kind with Quick Look; this
/// only labels it.
public enum FileKind: String, Sendable, Hashable, CaseIterable {
    case image, pdf, text, code, spreadsheet, document, presentation, archive, audio, video, other

    public init(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        self = Self.byExtension[ext] ?? .other
    }

    /// An SF Symbol for the kind.
    public var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.plaintext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .spreadsheet: "tablecells"
        case .document: "doc.text"
        case .presentation: "rectangle.on.rectangle"
        case .archive: "doc.zipper"
        case .audio: "waveform"
        case .video: "film"
        case .other: "doc"
        }
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: [String]) { for ext in extensions { map[ext] = kind } }
        add(.image, Array(TranscriptImage.imageExtensions))
        add(.pdf, ["pdf"])
        add(.text, ["txt", "md", "markdown", "rst", "log", "rtf"])
        add(.code, ["swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "toml", "xml", "html", "htm", "css",
                    "sh", "zsh", "bash", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "rb", "php", "sql",
                    "ini", "cfg", "conf", "diff", "patch", "ipynb"])
        add(.spreadsheet, ["csv", "tsv", "xls", "xlsx", "numbers", "ods"])
        add(.document, ["doc", "docx", "pages", "odt", "epub"])
        add(.presentation, ["ppt", "pptx", "key", "odp"])
        add(.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"])
        add(.audio, ["mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff"])
        add(.video, ["mp4", "mov", "m4v", "webm", "mkv", "avi"])
        return map
    }()
}
