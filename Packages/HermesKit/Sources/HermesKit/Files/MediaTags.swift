import Foundation

/// A file Hermes sent in a reply with a `MEDIA:<path>` tag: a path on the gateway's disk.
public struct DeliveredFile: Sendable, Hashable, Identifiable {
    /// As the tag wrote it (absolute, `~/`, or relative to the session's folder).
    public var path: String

    public init(path: String) {
        self.path = path
    }

    public var id: String { path }

    /// The file name shown on its card.
    public var name: String { AttachmentRefs.displayName(path) }

    public var kind: FileKind { FileKind(filename: name) }

    /// Shown as an image card: its thumbnail is read like a sent image's (`imageData`;
    /// the apps draw SVG with Quick Look).
    public var isImage: Bool { TranscriptImage.isImagePath(path) }
}

/// `MEDIA:<path>` tags in assistant text: how Hermes delivers files to a graphical
/// chat. The system prompt for the `desktop` surface (which the dashboard chat
/// uses) tells the model to "Deliver files by writing MEDIA:/absolute/path/to/file"
/// (`agent/prompt_builder.py:749-756`), and nothing else carries files: no event
/// or message field does (`apps/shared/src/gateway-contract.openrpc.json`).
///
/// Parsed as Desktop parses them (`apps/desktop/src/lib/chat-messages/parts.ts:121-300`,
/// `renderMediaTags` / `mediaTagValues`), with one difference `[client choice]`:
/// Desktop turns a tag into an inline link; here a tag on its own line is removed
/// and an inline one becomes the file's name, and the files show as cards right
/// after the line that held the tag (`segments`). Tags in fenced code blocks are examples, not deliveries, and are
/// left alone (Hermes' own cleanup masks code too, `gateway/platforms/base.py:1316`).
public enum MediaTags {
    public static let prefix = "MEDIA:"

    /// Hermes' `MEDIA_DELIVERY_EXTS` (`gateway/platforms/base.py:1289`, mirrored by
    /// Desktop's `parts.ts:121-180`): an unquoted path may contain spaces only when it
    /// ends in one of these.
    static let deliveryExtensions = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg",
        "mp4", "mov", "avi", "mkv", "webm", "3gp",
        "mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac",
        "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub",
        "xlsx", "xls", "ods", "csv", "tsv", "json", "xml", "yaml", "yml",
        "kmz", "kml", "geojson", "gpx",
        "pptx", "ppt", "odp", "key",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa",
        "html", "htm",
    ]

    private static let value: String = {
        let alternation = deliveryExtensions.sorted { $0.count > $1.count }.joined(separator: "|")
        let anchored = #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + alternation
            + #")(?=[\s`"'*_,;:)\]}]|MEDIA:|$)"#
        return #"(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|"# + anchored + #"|[^\s`"]+)"#
    }()

    /// Desktop's `MEDIA_LINE_RE`: a tag alone on its line.
    private static let lineExpression = try! NSRegularExpression(
        pattern: #"(^|\n)[\t ]*[`"']?MEDIA:\s*"# + value + #"[`"']?[\t ]*(\n|$)"#)
    /// Desktop's `MEDIA_TAG_RE`: a tag anywhere.
    private static let tagExpression = try! NSRegularExpression(pattern: #"[`"']?MEDIA:\s*"# + value + #"[`"']?"#)

    /// Sentence punctuation that can trail a bare path in prose.
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// A run of a reply as shown: Markdown, or the files delivered at that point.
    public enum Segment: Sendable, Hashable {
        case markdown(String)
        case files([DeliveredFile])
    }

    /// The reply split where its files were delivered, so each card shows where the
    /// tag was (like Desktop's inline link), not all at the end. A line holding a tag
    /// ends the Markdown before it: the line itself stays (its tags replaced by the
    /// file names) unless it was only the tag, and the files follow it. Each file shows
    /// once, at its first tag; adjacent files share one segment.
    /// - Parameter isStreaming: the reply is still arriving: a tag on its unfinished
    ///   last line may be a partial path, so that line is held back (neither shown
    ///   nor read) until it is complete.
    public static func segments(_ text: String, isStreaming: Bool = false) -> [Segment] {
        guard text.contains(prefix) else { return text.isEmpty ? [] : [.markdown(text)] }
        var body = text
        if isStreaming {
            let lastLine = body.lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
            if body[lastLine...].contains(prefix) { body = String(body[..<lastLine]) }
        }
        var segments: [Segment] = []
        var chunk: [String] = []
        var seen = Set<String>()
        func flushText() {
            let markdown = chunk.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            chunk = []
            guard !markdown.isEmpty else { return }
            segments.append(.markdown(markdown))
        }
        var fenced = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                chunk.append(String(line))
                continue
            }
            guard !fenced, line.contains(prefix) else {
                chunk.append(String(line))
                continue
            }
            var files: [DeliveredFile] = []
            let shown = rewrite(String(line), into: &files)
            files = files.filter { seen.insert($0.path).inserted }
            if !shown.trimmingCharacters(in: .whitespaces).isEmpty { chunk.append(shown) }
            guard !files.isEmpty else { continue }
            flushText()
            if case .files(let earlier) = segments.last {
                segments[segments.count - 1] = .files(earlier + files)
            } else {
                segments.append(.files(files))
            }
        }
        flushText()
        return segments
    }

    /// The text to show and the files it delivers, in order, each once.
    public static func extract(_ text: String, isStreaming: Bool = false) -> (text: String, files: [DeliveredFile]) {
        guard text.contains(prefix) else { return (text, []) }
        var markdown: [String] = []
        var files: [DeliveredFile] = []
        for segment in segments(text, isStreaming: isStreaming) {
            switch segment {
            case .markdown(let text): markdown.append(text)
            case .files(let delivered): files += delivered
            }
        }
        return (markdown.joined(separator: "\n\n"), files)
    }

    /// Lines with a tag alone go; other tags become the file's name.
    private static func rewrite(_ text: String, into files: inout [DeliveredFile]) -> String {
        guard text.contains(prefix) else { return text }
        var result = replace(lineExpression, in: text) { match, string in
            guard let file = file(from: string.substring(with: match.range(at: 2))) else { return nil }
            files.append(file.file)
            // Keep one line break where the tag's line was.
            let lead = string.substring(with: match.range(at: 1))
            let trailer = string.substring(with: match.range(at: 3))
            return lead.isEmpty || trailer.isEmpty ? lead + trailer : "\n"
        }
        result = replace(tagExpression, in: result) { match, string in
            guard let file = file(from: string.substring(with: match.range(at: 1))) else { return nil }
            files.append(file.file)
            return file.file.name + file.punctuation
        }
        // A removed line between paragraphs leaves no extra blank line.
        return result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func replace(_ expression: NSRegularExpression, in text: String,
                                with transform: (NSTextCheckingResult, NSString) -> String?) -> String {
        let string = text as NSString
        var result = ""
        var last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            guard let replacement = transform(match, string) else { continue }
            result += string.substring(with: NSRange(location: last, length: match.range.location - last))
            result += replacement
            last = match.range.location + match.range.length
        }
        result += string.substring(from: last)
        return result
    }

    /// A captured value as a file: quotes stripped; a bare value sheds the sentence
    /// punctuation after it (`splitTrailingPunctuation`). `nil` for a value that
    /// cannot name a file (`isPlausibleMediaPath`).
    private static func file(from raw: String) -> (file: DeliveredFile, punctuation: String)? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        var path: Substring
        var punctuation: Substring = ""
        if let first = value.first, "`\"'".contains(first), value.count >= 2, value.last == first {
            path = value.dropFirst().dropLast()
        } else {
            path = Substring(value)
            if let last = path.last, last == "`" || last == "\"" { path = path.dropLast() }
            var end = path.endIndex
            while end > path.startIndex, trailingPunctuation.contains(path[path.index(before: end)]),
                isPlausible(path[..<path.index(before: end)])
            {
                end = path.index(before: end)
            }
            punctuation = path[end...]
            path = path[..<end]
        }
        guard isPlausible(path) else { return nil }
        return (DeliveredFile(path: String(path)), String(punctuation))
    }

    /// A path separator, or a dot with something after it.
    private static func isPlausible(_ value: Substring) -> Bool {
        if value.contains("/") || value.contains("\\") { return true }
        return zip(value, value.dropFirst()).contains { $0 == "." && $1 != "." }
    }
}
