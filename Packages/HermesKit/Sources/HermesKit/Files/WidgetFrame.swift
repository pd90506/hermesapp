import Foundation
import HermesProtocol

/// The page a `::preview` widget runs in, and the messages it may send back: the Swift
/// twin of the Electron app's `widget-frame.ts`, which adapts the official Hermes Desktop's
/// `inline-preview-directive.tsx` (hermes-agent, MIT, see THIRD_PARTY_NOTICES.md). The
/// same theme prelude names, the same size report and `hermes.send` script, the same
/// limits; `Packages/fixtures/reply-embeds.json` pins that both write the very same page.
/// Everything a frame posts is untrusted, so only a message with its mount's token counts.
///
/// The iOS app runs the page in a `WKWebView` the way Desktop runs it in an `<iframe>`:
/// a trusted host page (`hostPage`) holds it in a `sandbox="allow-scripts"` frame, so its
/// scripts run with an opaque origin and reach nothing of the app, and the host passes
/// the frame's messages to the app (`docs/protocol.md` §10.11).
public enum WidgetFrame {
    public static let minHeight = 120
    public static let maxHeight = 1200
    public static let defaultHeight = 280
    /// The frame spans the reply's column up to this (Desktop's `MAX_FRAME_WIDTH`).
    public static let maxWidth = 960
    /// Sub-pixel churn ignored, so a page sized by `vh` cannot oscillate.
    public static let resizeTolerance = 4

    static let sizeMessage = "hermes-inline-preview-size"
    static let intentMessage = "hermes-inline-preview-intent"
    static let intentAckMessage = "hermes-inline-preview-intent-ack"

    /// A widget's prompt is a sentence, not a payload: a longer one is refused, never cut.
    public static let maxIntentLength = 500
    /// One prompt a second per frame; a faster one is refused with `retryAfterMs`.
    public static let intentThrottleMs: Double = 1000
    static let intentAckTimeoutMs = 5000

    // MARK: Heights

    /// `height="…"`: the starting height only, inside the band.
    public static func initialHeight(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = trimmed.isEmpty ? 0 : Double(trimmed)
        guard let parsed, parsed.isFinite, parsed.rounded() == parsed else { return nil }
        return Int(min(Double(maxHeight), max(Double(minHeight), parsed)))
    }

    /// A size report from the frame with this token, clamped to the band; otherwise nil.
    public static func reportedHeight(_ data: JSONValue, token: String) -> Int? {
        guard data["type"]?.stringValue == sizeMessage, data["token"]?.stringValue == token,
            let height = data["height"]?.doubleValue, height.isFinite, height > 0
        else { return nil }
        return Int(min(Double(maxHeight), max(Double(minHeight), height.rounded())))
    }

    // MARK: Prompts

    public enum IntentError: String, Sendable, Hashable {
        case invalid
        case tooLong = "too_long"
        case throttled
        case undelivered
    }

    /// The answer a prompt gets: `{ok: true}`, or why not.
    public struct IntentAck: Sendable, Hashable {
        public var error: IntentError?
        public var maxLength: Int?
        public var retryAfterMs: Double?

        public static let ok = IntentAck()

        public init(error: IntentError? = nil, maxLength: Int? = nil, retryAfterMs: Double? = nil) {
            self.error = error
            self.maxLength = maxLength
            self.retryAfterMs = retryAfterMs
        }

        public var json: JSONValue {
            guard let error else { return .object(["ok": .bool(true)]) }
            var object: [String: JSONValue] = ["ok": .bool(false), "error": .string(error.rawValue)]
            if let maxLength { object["maxLength"] = .number(Double(maxLength)) }
            if let retryAfterMs { object["retryAfterMs"] = .number(retryAfterMs) }
            return .object(object)
        }
    }

    public enum IntentDecision: Sendable, Hashable {
        case accept(id: Int?, prompt: String)
        case reject(id: Int?, ack: IntentAck)

        public var id: Int? {
            switch self {
            case .accept(let id, _), .reject(let id, _): id
            }
        }
    }

    /// A prompt from the frame with this token: accepted (trimmed) or refused with a
    /// reason; nil for any other message. Times in milliseconds; `lastAcceptedAt` 0 is never.
    public static func evaluateIntent(_ data: JSONValue, token: String, now: Double,
                                      lastAcceptedAt: Double) -> IntentDecision? {
        guard data["type"]?.stringValue == intentMessage, data["token"]?.stringValue == token else { return nil }
        var id: Int?
        if let raw = data["id"]?.doubleValue, raw.rounded() == raw, abs(raw) <= 9_007_199_254_740_991 { id = Int(raw) }
        let prompt = data["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prompt.isEmpty { return .reject(id: id, ack: IntentAck(error: .invalid)) }
        if prompt.utf16.count > maxIntentLength {
            return .reject(id: id, ack: IntentAck(error: .tooLong, maxLength: maxIntentLength))
        }
        let elapsed = now - lastAcceptedAt
        if lastAcceptedAt > 0, elapsed < intentThrottleMs {
            return .reject(id: id, ack: IntentAck(error: .throttled, retryAfterMs: intentThrottleMs - elapsed))
        }
        return .accept(id: id, prompt: prompt)
    }

    /// The message answering prompt `id`.
    public static func intentAck(token: String, id: Int, ack: IntentAck) -> JSONValue {
        .object(["type": .string(intentAckMessage), "token": .string(token), "id": .number(Double(id)), "ack": ack.json])
    }

    // MARK: The page

    /// The app's colours under the names Hermes teaches the model, in this order.
    public static let themeNames = ["--foreground", "--muted-foreground", "--accent", "--border", "--card"]

    public struct Theme: Sendable, Hashable {
        /// CSS colours by `themeNames`; a name left out is not set.
        public var vars: [String: String]
        /// A CSS `font-family` value; empty sets none.
        public var font: String
        public var isDark: Bool

        public init(vars: [String: String], font: String, isDark: Bool) {
            self.vars = vars
            self.font = font
            self.isDark = isDark
        }

        var colorScheme: String { isDark ? "dark" : "light" }
    }

    /// Injected first, so the page's own styles win: the colours, the scheme, the font,
    /// no margins, a clear canvas.
    static func themePrelude(_ theme: Theme) -> String {
        let tokens = themeNames.compactMap { name in theme.vars[name].map { "\(name):\($0)" } }.joined(separator: ";")
        let font = theme.font.isEmpty ? "" : "font-family:\(theme.font);"
        return "<style>:root{color-scheme:\(theme.colorScheme);\(tokens)}"
            + "html,body{margin:0;padding:0;background:transparent;color:var(--foreground,inherit);\(font)}</style>"
    }

    /// Reports the content's height; postMessage is the frame's only door.
    static func measurementScript(_ token: String) -> String {
        "<script>(function(){var t=" + jsString(token)
            + ";var lastH=0;function post(){var d=document.documentElement;var b=document.body;"
            + "var h=Math.max(d?d.scrollHeight:0,b?b.scrollHeight:0);"
            + "if(Math.abs(h-lastH)>1){lastH=h;parent.postMessage({type:" + jsString(sizeMessage)
            + ",token:t,height:h},\"*\")}}"
            + "if(typeof ResizeObserver===\"function\"){var ro=new ResizeObserver(post);"
            + "ro.observe(document.documentElement);if(document.body)ro.observe(document.body)}"
            + "addEventListener(\"load\",post);post()})()</script>"
    }

    /// `hermes.send(prompt)` and `data-hermes-send="…"`: a prompt, answered by an ack.
    static func intentScript(_ token: String) -> String {
        "<script>(function(){var t=" + jsString(token) + ";var n=0,w={};"
            + "addEventListener(\"message\",function(e){var d=e.data;"
            + "if(e.source!==parent||!d||d.type!==" + jsString(intentAckMessage)
            + "||d.token!==t||!w[d.id])return;var r=w[d.id];delete w[d.id];r(d.ack)});"
            + "function send(p){if(typeof p!==\"string\"||!p.trim())return Promise.resolve({ok:false,error:\"invalid\"});"
            + "var id=++n;return new Promise(function(res){var done=function(a){clearTimeout(k);res(a)};"
            + "var k=setTimeout(function(){if(w[id]){delete w[id];res({ok:false,error:\"undelivered\"})}},"
            + String(intentAckTimeoutMs) + ");w[id]=done;parent.postMessage({type:" + jsString(intentMessage)
            + ",token:t,id:id,prompt:p},\"*\")})}"
            + "window.hermes={send:send,maxLength:" + String(maxIntentLength) + "};"
            + "addEventListener(\"click\",function(e){var el=e.target&&e.target.closest?"
            + "e.target.closest(\"[data-hermes-send]\"):null;"
            + "if(el)send(el.getAttribute(\"data-hermes-send\")||\"\")},true)})()</script>"
    }

    private static let bodyClose = try! NSRegularExpression(pattern: #"</body\s*>"#, options: .caseInsensitive)
    private static let doctype = try! NSRegularExpression(pattern: #"^\s*<!doctype[^>]*>"#, options: .caseInsensitive)

    /// The page as served: the prelude first (after a `<!doctype>`, which must lead or the
    /// page renders in quirks mode), the scripts before `</body>` (or at the end).
    public static func document(_ html: String, token: String, theme: Theme) -> String {
        let scripts = measurementScript(token) + intentScript(token)
        let source = html as NSString
        let framed: String
        if let close = bodyClose.firstMatch(in: html, range: NSRange(location: 0, length: source.length)) {
            framed = source.substring(to: close.range.location) + scripts + source.substring(from: close.range.location)
        } else {
            framed = html + scripts
        }
        let page = framed as NSString
        let lead = doctype.firstMatch(in: framed, range: NSRange(location: 0, length: page.length))
        let doctypeText = lead.map { page.substring(with: $0.range) }
        let rest = lead.map { page.substring(from: $0.range.length) } ?? framed
        return (doctypeText ?? "<!doctype html>") + "<meta charset=\"utf-8\">" + themePrelude(theme) + rest
    }

    // MARK: The host page (iOS)

    /// The name the host page posts to (`WKScriptMessageHandler`).
    public static let hostHandler = "hermesWidget"
    /// The host's function that hands a message to the frame (an intent's ack).
    public static let hostReplyFunction = "__hermesWidgetReply"

    /// The trusted page the `WKWebView` loads: `document` in a `sandbox="allow-scripts"`
    /// frame (never `allow-same-origin`), as Desktop frames it. It passes on only what the
    /// frame itself posts, and hands the app's answers back to it. A `srcdoc` frame takes
    /// the host's content policy, and the host sets none: Hermes gives its own previews
    /// any script, style, image, font or fetch source (`hermes_cli/webapp_previews.py`,
    /// `_GUEST_SOURCES`), as the isolation is the sandbox.
    public static func hostPage(document: String, title: String, isDark: Bool) -> String {
        let scheme = isDark ? "dark" : "light"
        return "<!doctype html><html><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1\">"
            + "<meta name=\"referrer\" content=\"no-referrer\">"
            + "<style>:root{color-scheme:\(scheme)}html,body{margin:0;padding:0;background:transparent;overflow:hidden}"
            + "iframe{display:block;border:0;width:100%;height:100vh;background:transparent;color-scheme:\(scheme)}</style>"
            + "</head><body><iframe sandbox=\"allow-scripts\" referrerpolicy=\"no-referrer\" title=\"\(htmlAttribute(title))\"></iframe>"
            + "<script>(function(){var f=document.querySelector(\"iframe\");"
            + "var m=window.webkit&&window.webkit.messageHandlers;var h=m&&m." + hostHandler + ";"
            + "addEventListener(\"message\",function(e){if(!h||e.source!==f.contentWindow)return;"
            + "try{h.postMessage(e.data)}catch(_){}});"
            + "window." + hostReplyFunction + "=function(d){if(f.contentWindow)f.contentWindow.postMessage(d,\"*\")};"
            + "f.srcdoc=" + scriptString(document) + "})()</script></body></html>"
    }

    /// A JavaScript call handing `message` to the frame.
    public static func replyScript(_ message: JSONValue) -> String {
        "window." + hostReplyFunction + "(" + jsonText(message) + ")"
    }

    // MARK: Text

    /// A string literal as `JSON.stringify` writes it.
    static func jsString(_ value: String) -> String {
        var out = "\""
        for unit in value.unicodeScalars {
            switch unit {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let scalar where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(unit)
            }
        }
        return out + "\""
    }

    /// A string literal safe inside a `<script>` element: no `</script>`, no line separators.
    static func scriptString(_ value: String) -> String {
        jsString(value)
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "<!--", with: "<\\!--")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func jsonText(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number):
            number.isFinite ? (number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)) : "null"
        case .string(let string): scriptString(string)
        case .array(let items): "[" + items.map(jsonText).joined(separator: ",") + "]"
        case .object(let object):
            "{" + object.keys.sorted().map { scriptString($0) + ":" + jsonText(object[$0]!) }.joined(separator: ",") + "}"
        }
    }

    private static func htmlAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
