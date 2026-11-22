import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// `Packages/fixtures/reply-embeds.json`: the directive reading and the widget page the
/// Electron app (hermes-core's `directives.ts`, the app's `widget-frame.ts`) pins too.
@Suite struct ReplyEmbedFixtureTests {
    static let fixture: JSONValue = {
        let url = SharedFixtureTests.directory.appendingPathComponent("reply-embeds.json")
        return try! JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }()

    static func cases(_ name: String) -> [JSONValue] { fixture[name]?.arrayValue ?? [] }

    static func json(_ segment: TranscriptDirectives.Segment) -> JSONValue {
        switch segment {
        case .markdown(let text): ["kind": "markdown", "text": .string(text)]
        case .directive(let directive):
            ["kind": "directive", "name": .string(directive.name),
             "attrs": .object(directive.attrs.mapValues { .string($0) }), "source": .string(directive.source)]
        }
    }

    static func json(_ target: PreviewTarget?) -> JSONValue {
        switch target {
        case .html(let path)?: ["kind": "html", "path": .string(path)]
        case .file(let path)?: ["kind": "file", "path": .string(path)]
        case .url(let url)?: ["kind": "url", "url": .string(url.absoluteString)]
        case nil: .null
        }
    }

    static func json(_ decision: WidgetFrame.IntentDecision?) -> JSONValue {
        let id: (Int?) -> JSONValue = { $0.map { .number(Double($0)) } ?? .null }
        switch decision {
        case .accept(let ident, let prompt)?: return ["kind": "accept", "id": id(ident), "prompt": .string(prompt)]
        case .reject(let ident, let ack)?: return ["kind": "reject", "id": id(ident), "ack": ack.json]
        case nil: return .null
        }
    }

    @Test func directives() {
        let cases = Self.cases("directives")
        #expect(!cases.isEmpty)
        for item in cases {
            let text = item["text"]?.stringValue ?? ""
            let segments = TranscriptDirectives.segments(text, isStreaming: item["streaming"]?.boolValue == true)
            #expect(JSONValue.array(segments.map(Self.json)) == item["segments"], "\(text)")
        }
    }

    @Test func previewTargets() {
        for item in Self.cases("previewTargets") {
            let file = item["file"]?.stringValue
            #expect(Self.json(PreviewTarget(file: file)) == item["target"], "\(file ?? "")")
        }
    }

    @Test func heights() {
        for item in Self.cases("initialHeights") {
            let height = WidgetFrame.initialHeight(item["raw"]?.stringValue).map { JSONValue.number(Double($0)) } ?? .null
            #expect(height == item["height"], "\(item)")
        }
        for item in Self.cases("reportedHeights") {
            let height = WidgetFrame.reportedHeight(item["data"] ?? .null, token: item["token"]?.stringValue ?? "")
                .map { JSONValue.number(Double($0)) } ?? .null
            #expect(height == item["height"], "\(item)")
        }
    }

    @Test func intents() {
        for item in Self.cases("intents") {
            let decision = WidgetFrame.evaluateIntent(item["data"] ?? .null, token: item["token"]?.stringValue ?? "",
                                                      now: item["now"]?.doubleValue ?? 0,
                                                      lastAcceptedAt: item["lastAcceptedAt"]?.doubleValue ?? 0)
            #expect(Self.json(decision) == item["decision"], "\(item)")
        }
    }

    /// The very page the desktop app serves, byte for byte.
    @Test func widgetDocuments() {
        let cases = Self.cases("widgetDocuments")
        #expect(cases.count >= 4)
        for item in cases {
            let theme = item["theme"]
            let vars = (theme?["vars"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            let page = WidgetFrame.document(
                item["html"]?.stringValue ?? "", token: item["token"]?.stringValue ?? "",
                theme: WidgetFrame.Theme(vars: vars, font: theme?["font"]?.stringValue ?? "",
                                         isDark: theme?["colorScheme"]?.stringValue == "dark"))
            #expect(page == item["document"]?.stringValue)
        }
    }
}

@Suite struct ReplyPartsTests {
    @Test func plainRepliesStayOneRun() {
        #expect(ReplyParts.segments("Just text.") == [.markdown("Just text.")])
        #expect(ReplyParts.segments("") == [])
    }

    @Test func aLineOfWebImagesShowsAsImages() throws {
        let text = "Here:\n\n![A cat](https://example.com/cat.png) ![](<https://example.com/dog.jpg> \"Dog\")\n\nNice?"
        let url1 = try #require(URL(string: "https://example.com/cat.png"))
        let url2 = try #require(URL(string: "https://example.com/dog.jpg"))
        #expect(ReplyParts.segments(text) == [
            .markdown("Here:"),
            .images([WebImage(url: url1, alt: "A cat"), WebImage(url: url2, alt: "")]),
            .markdown("Nice?"),
        ])
        #expect(WebImage(url: url2, alt: "").name == "dog.jpg")
    }

    @Test func imagesInProseCodeOrLocalStayText() {
        let inline = "See ![x](https://example.com/x.png) here"
        #expect(ReplyParts.segments(inline) == [.markdown(inline)])
        let fenced = "```\n![x](https://example.com/x.png)\n```"
        #expect(ReplyParts.segments(fenced) == [.markdown(fenced)])
        let local = "![x](/tmp/x.png)"
        #expect(ReplyParts.segments(local) == [.markdown(local)])
        let half = "![x](https://example.com/x.png) and more"
        #expect(ReplyParts.segments(half) == [.markdown(half)])
    }

    @Test func widgetsFilesAndImagesKeepTheirPlaces() throws {
        let text = "Chart:\n::preview{file=\"chart.html\" height=\"400\"}\nFile:\nMEDIA:/tmp/a.csv\n![p](https://x.example/p.png)"
        let segments = ReplyParts.segments(text)
        #expect(segments == [
            .markdown("Chart:"),
            .directive(TranscriptDirective(name: "preview", attrs: ["file": "chart.html", "height": "400"],
                                           source: "::preview{file=\"chart.html\" height=\"400\"}")),
            .markdown("File:"),
            .files([DeliveredFile(path: "/tmp/a.csv")]),
            .images([WebImage(url: try #require(URL(string: "https://x.example/p.png")), alt: "p")]),
        ])
    }

    @Test func aDirectiveStillBeingWrittenWaits() {
        #expect(ReplyParts.segments("Done.\n::preview{file=\"a.ht", isStreaming: true) == [.markdown("Done.")])
    }
}

@Suite struct WidgetHostPageTests {
    @Test func theHostSandboxesThePageAndCannotBeClosedByIt() {
        let page = WidgetFrame.document("<p>x</p></script><script>alert(1)</script>", token: "t",
                                        theme: WidgetFrame.Theme(vars: [:], font: "", isDark: true))
        let host = WidgetFrame.hostPage(document: page, title: "a\"b.html", isDark: true)
        #expect(host.contains("<iframe sandbox=\"allow-scripts\""))
        #expect(!host.contains("allow-same-origin"))
        #expect(host.contains("title=\"a&quot;b.html\""))
        // The page travels as one string literal: its `</script>` cannot end the host's script.
        let script = host.components(separatedBy: "f.srcdoc=")[1]
        #expect(script.components(separatedBy: "</script>").count == 2)
        #expect(host.contains("e.source!==f.contentWindow"))
    }

    @Test func anAckReachesTheFrameAsJSON() {
        let ack = WidgetFrame.intentAck(token: "t</", id: 3, ack: .init(error: .throttled, retryAfterMs: 600))
        #expect(WidgetFrame.replyScript(ack) == "window.__hermesWidgetReply({\"ack\":{\"error\":\"throttled\",\"ok\":false,"
            + "\"retryAfterMs\":600},\"id\":3,\"token\":\"t<\\/\",\"type\":\"hermes-inline-preview-intent-ack\"})")
    }
}

@Suite struct EmbedReadTests {
    @Test func aPageIsReadAsTextAndOnlyARelativePathNamesTheChat() async throws {
        let api = FakeDashboardAPI(["GET /api/fs/read-text": ["text": "<p>hi</p>", "binary": false, "truncated": false]])
        let file = try await GatewayConnection.readText(api, path: "chart.html", profile: "coder", sessionKey: "stored-1")
        #expect(file == GatewayTextFile(text: "<p>hi</p>", binary: false, truncated: false))
        _ = try await GatewayConnection.readText(api, path: "/tmp/chart.html", profile: "coder", sessionKey: "stored-1")
        #expect(api.calls.map(\.query) == [
            ["path": "chart.html", "profile": "coder", "session_id": "stored-1"],
            ["path": "/tmp/chart.html", "profile": "coder"],
        ])
    }

    @Test func aWebImageThroughTheGatewayProxy() async throws {
        let api = FakeDashboardAPI(["GET /api/media/proxy": ["data_url": "data:image/png;base64,AAE="]])
        let url = try #require(URL(string: "https://cdn.example.com/x.png"))
        #expect(try await GatewayConnection.proxiedImage(api, url: url) == Data([0, 1]))
        #expect(api.calls.first?.query == ["url": "https://cdn.example.com/x.png"])
        let refusing = FakeDashboardAPI(["GET /api/media/proxy": ["data_url": "data:text/html;base64,AAE="]])
        await #expect(throws: EmbedReadError.noImage) { try await GatewayConnection.proxiedImage(refusing, url: url) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HiddenPromptTests {
    private let connections = ConnectionKeeper()

    @Test func aWidgetPromptGoesAsAHiddenTurnWithNoBubble() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        let session = try await connection.newSession()

        #expect(await session.sendHidden("  refresh the chart "))
        #expect(gateway.params("prompt.submit") == [
            ["session_id": "sid-1", "text": "refresh the chart", "display_kind": "hidden"],
        ])
        #expect(!session.transcript.items.contains { $0.role == .user })
        #expect(await session.sendHidden("   ") == false)
    }
}
