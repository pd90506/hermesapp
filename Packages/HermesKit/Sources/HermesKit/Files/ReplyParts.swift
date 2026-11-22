import Foundation

/// A web image a reply shows: `![alt](https://…)`.
public struct WebImage: Sendable, Hashable, Identifiable {
    public var url: URL
    public var alt: String

    public init(url: URL, alt: String) {
        self.url = url
        self.alt = alt
    }

    public var id: String { url.absoluteString }

    /// What names it: its alt text, else the URL's last part.
    public var name: String {
        if !alt.isEmpty { return alt }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? url.absoluteString : last
    }
}

/// A reply as the iOS chat shows it: Markdown runs, the files it delivered (`MEDIA:`
/// tags, `MediaTags`), its widgets (`::preview`, `TranscriptDirectives`) and its web
/// images, each where it was written, as the Electron app's `MediaMarkdown` splits one.
///
/// `[client choice]` A web image shows as an image when its line holds only images
/// (`![alt](https://…)`, one or more, outside code); one inside a sentence, a list or a
/// quote stays its link. Desktop draws every `![alt](url)` in place, but the native
/// Markdown view lays text out as attributed runs, where an image cannot sit; models
/// put images on a line of their own. Hermes tells the model local files go by
/// `MEDIA:` only, so only `http(s)` images count.
public enum ReplyParts {
    public enum Segment: Sendable, Hashable {
        case markdown(String)
        case files([DeliveredFile])
        case directive(TranscriptDirective)
        case images([WebImage])
    }

    /// The reply split into what shows. `isStreaming`: the reply is still arriving; the
    /// unfinished last line waits as each part's reader says.
    public static func segments(_ text: String, isStreaming: Bool = false) -> [Segment] {
        let parts = TranscriptDirectives.segments(text, isStreaming: isStreaming)
        var segments: [Segment] = []
        for (index, part) in parts.enumerated() {
            let last = isStreaming && index == parts.count - 1
            switch part {
            case .directive(let directive):
                segments.append(.directive(directive))
            case .markdown(let markdown):
                for media in MediaTags.segments(markdown, isStreaming: last) {
                    switch media {
                    case .files(let files): segments.append(.files(files))
                    case .markdown(let run): segments += imageSegments(run)
                    }
                }
            }
        }
        return segments
    }

    /// Whether the reply has anything but Markdown: without, it shows as one run.
    public static func hasEmbeds(_ text: String) -> Bool {
        text.contains(MediaTags.prefix) || TranscriptDirectives.mayContain(text) || text.contains("](")
    }

    /// A line of only images: `![alt](url "title")`, spaces between.
    private static let imageLine = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:!\[[^\]\n]*\]\([^()\n]*\)[ \t]*)+$"#)
    private static let image = try! NSRegularExpression(
        pattern: #"!\[([^\]\n]*)\]\(\s*<?([^\s()<>]+)>?(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\s*\)"#)

    /// A Markdown run split around its lines of only web images.
    static func imageSegments(_ text: String) -> [Segment] {
        guard text.contains("![") else { return [.markdown(text)] }
        var segments: [Segment] = []
        var chunk: [String] = []
        func flush() {
            let markdown = chunk.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            chunk = []
            if !markdown.isEmpty { segments.append(.markdown(markdown)) }
        }
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                chunk.append(line)
                continue
            }
            guard !fenced, let images = images(in: line) else {
                chunk.append(line)
                continue
            }
            flush()
            if case .images(let earlier) = segments.last {
                segments[segments.count - 1] = .images(earlier + images)
            } else {
                segments.append(.images(images))
            }
        }
        flush()
        return segments
    }

    /// The images of a line holding only web images; nil for any other line.
    static func images(in line: String) -> [WebImage]? {
        let string = line as NSString
        let whole = NSRange(location: 0, length: string.length)
        guard line.contains("!["), imageLine.firstMatch(in: line, range: whole) != nil else { return nil }
        let matches = image.matches(in: line, range: whole)
        // Every image read in full: nothing of the line is lost.
        let covered = matches.reduce(0) { $0 + $1.range.length }
        let spaces = line.unicodeScalars.filter { $0 == " " || $0 == "\t" }.count
        let between = matches.reduce(0) { total, match in
            total + string.substring(with: match.range).unicodeScalars.filter { $0 == " " || $0 == "\t" }.count
        }
        guard covered + spaces - between == string.length else { return nil }
        var found: [WebImage] = []
        for match in matches {
            let raw = string.substring(with: match.range(at: 2))
            let lower = raw.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), let url = URL(string: raw),
                url.host != nil
            else { return nil }
            found.append(WebImage(url: url, alt: string.substring(with: match.range(at: 1))))
        }
        return found.isEmpty ? nil : found
    }
}
