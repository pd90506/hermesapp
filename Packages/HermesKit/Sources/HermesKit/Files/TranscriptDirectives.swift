import Foundation

/// A `::name{key="value"}` directive in a reply (`TranscriptDirectives`).
public struct TranscriptDirective: Sendable, Hashable {
    public var name: String
    /// Lowercased keys; values as written.
    public var attrs: [String: String]
    /// The directive's text, for a fallback.
    public var source: String

    public init(name: String, attrs: [String: String], source: String) {
        self.name = name
        self.attrs = attrs
        self.source = source
    }
}

/// Transcript directives: `::name{key="value"}` in a reply, which a graphical chat draws
/// as a component in place (`docs/protocol.md` §10.11). Hermes' `desktop` system prompt
/// teaches one, `::preview{file="path.html"}`: an HTML file the agent wrote, shown live
/// in the message (`agent/prompt_builder.py`, `PLATFORM_HINTS["desktop"]`).
///
/// The Swift twin of hermes-core's `media/directives.ts`, which reads them as Desktop does
/// (`apps/desktop/src/lib/transcript-directives.ts`); both are pinned by
/// `Packages/fixtures/reply-embeds.json`. A directive starts wherever a word can start (so
/// `std::vector` never is one), only a name the app claims is drawn (any other stays the
/// text it was), and a brace the attributes could not close leaves the whole thing as
/// text. Attributes are untrusted model output. `[client choice]` Directives in fenced
/// code are examples and stay text, as `MEDIA:` tags do, and while a reply streams a
/// directive whose brace is still open on the last line waits.
public enum TranscriptDirectives {
    /// The directives the apps draw.
    public static let claimed = ["preview"]

    /// Desktop's `DIRECTIVE_BODY_MAX`: room for two signed CDN URLs and a title.
    public static let bodyLimit = 2048

    public enum Segment: Sendable, Hashable {
        case markdown(String)
        case directive(TranscriptDirective)
    }

    private static let segmentExpression = try! NSRegularExpression(
        pattern: #"(?<=^|\s)::([a-z][a-z0-9-]{0,63})(?:\{([^{}\n]{0,\#(bodyLimit)})\})?"#)
    private static let openBrace = try! NSRegularExpression(pattern: #"(?<=^|\s)::[a-z][a-z0-9-]{0,63}\{[^{}]*$"#)
    /// `key="value"`, single quotes accepted for model sloppiness (Desktop's `ATTR_RE`).
    private static let attrExpression = try! NSRegularExpression(
        pattern: #"([a-z][\w-]{0,63})=(?:"([^"]*)"|'([^']*)')"#, options: .caseInsensitive)
    /// Models copy the `<https://…>` autolink form into attributes too.
    private static let autolink = try! NSRegularExpression(pattern: #"^<(https?://[^<>\s]+)>$"#,
                                                           options: .caseInsensitive)

    /// Whether a reply may hold a directive at all (a cheap check before splitting).
    public static func mayContain(_ text: String) -> Bool { text.contains("::") }

    /// The reply split around the directives it holds, in order.
    public static func segments(_ text: String, isStreaming: Bool = false,
                                claimed: [String] = TranscriptDirectives.claimed) -> [Segment] {
        guard text.contains("::") else { return text.isEmpty ? [] : [.markdown(text)] }
        var body = text as NSString
        if isStreaming {
            let newline = body.range(of: "\n", options: .backwards)
            let lastLine = newline.location == NSNotFound ? 0 : newline.location + 1
            let tail = body.substring(from: lastLine)
            if openBrace.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) != nil {
                body = body.substring(to: lastLine) as NSString
            }
        }
        var segments: [Segment] = []
        var chunk: [String] = []
        func flush() {
            let markdown = chunk.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            chunk = []
            if !markdown.isEmpty { segments.append(.markdown(markdown)) }
        }
        var fenced = false
        for line in (body as String).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                chunk.append(line)
                continue
            }
            if fenced || !line.contains("::") {
                chunk.append(line)
                continue
            }
            let string = line as NSString
            var cursor = 0
            for match in segmentExpression.matches(in: line, range: NSRange(location: 0, length: string.length)) {
                let start = match.range.location
                let end = start + match.range.length
                let name = string.substring(with: match.range(at: 1))
                guard claimed.contains(name) else { continue }
                let bodyRange = match.range(at: 2)
                // A brace the attributes refused: half a directive is not one.
                if bodyRange.location == NSNotFound, end < string.length, string.character(at: end) == 0x7B { continue }
                let before = string.substring(with: NSRange(location: cursor, length: start - cursor))
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunk.append(before.trimmedEnd) }
                flush()
                let attrs = bodyRange.location == NSNotFound ? [:] : parseAttrs(string.substring(with: bodyRange))
                segments.append(.directive(TranscriptDirective(name: name, attrs: attrs,
                                                               source: string.substring(with: match.range))))
                cursor = end
            }
            let rest = string.substring(from: cursor)
            if cursor == 0 {
                chunk.append(line)
            } else if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunk.append(rest.trimmedStart)
            }
        }
        flush()
        return segments
    }

    private static func parseAttrs(_ body: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let string = body as NSString
        for pair in attrExpression.matches(in: body, range: NSRange(location: 0, length: string.length)) {
            let key = string.substring(with: pair.range(at: 1)).lowercased()
            let quoted = pair.range(at: 2).location != NSNotFound ? pair.range(at: 2) : pair.range(at: 3)
            let value = quoted.location == NSNotFound ? "" : string.substring(with: quoted)
            attrs[key] = autolink.stringByReplacingMatches(
                in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: "$1")
        }
        return attrs
    }
}

/// Where a `::preview` points: an HTML file to draw in place, another file, or a web page.
public enum PreviewTarget: Sendable, Hashable {
    case html(path: String)
    case file(path: String)
    case url(URL)

    private static let page = try! NSRegularExpression(pattern: #"\.(?:html?|xhtml)$"#, options: .caseInsensitive)

    /// Desktop's `localPreviewTarget`, without the cwd join: the gateway resolves a
    /// relative path against the chat's folder.
    public init?(file: String?) {
        var raw = (file ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("`") { raw.removeFirst() }
        if raw.hasSuffix("`") { raw.removeLast() }
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: raw) else { return nil }
            self = .url(url)
            return
        }
        var path = raw
        if lower.hasPrefix("file://") {
            if let url = URL(string: raw), !url.path.isEmpty {
                // `path` comes percent-decoded.
                path = url.path
                // `file:///C:/x` reads as `/C:/x`.
                if path.range(of: #"^/[A-Za-z]:[/\\]"#, options: .regularExpression) != nil { path.removeFirst() }
            } else {
                path = String(raw.dropFirst("file://".count))
            }
        }
        let range = NSRange(location: 0, length: (path as NSString).length)
        self = Self.page.firstMatch(in: path, range: range) != nil ? .html(path: path) : .file(path: path)
    }

    /// Whether a path is relative, so the gateway reads it against the chat's folder.
    public static func isRelative(_ path: String) -> Bool {
        !(path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("\\\\")
            || path.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil)
    }
}

extension String {
    fileprivate var trimmedEnd: String {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace { end = index(before: end) }
        return String(self[..<end])
    }

    fileprivate var trimmedStart: String { String(drop { $0.isWhitespace }) }
}
