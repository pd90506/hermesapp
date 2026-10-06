import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Images in user messages (docs/protocol.md §10.3): stored `@image:` lines become images,
// not text, and are read back through the dashboard.

@Suite struct ImageDirectivesTests {
    @Test func storedImageLinesBecomeImagesAndTheRestTheCaption() {
        // `_build_persist_message_with_image_refs` (`tui_gateway/session_history.py:51-60`).
        let (caption, paths) = ImageDirectives.split(
            "看这张图\n@image:/home/u/.hermes/images/upload_1.png\n@image:/home/u/.hermes/images/upload_2.jpg")
        #expect(caption == "看这张图")
        #expect(paths == ["/home/u/.hermes/images/upload_1.png", "/home/u/.hermes/images/upload_2.jpg"])
    }

    @Test func quotedPathsAsFormatReferenceValueWritesThem() {
        // `format_reference_value` quotes with the first of ` " ' the value lacks
        // (`agent/context_references.py:141-149`).
        #expect(ImageDirectives.split("@image:`/srv/my images/a (1).png`").paths == ["/srv/my images/a (1).png"])
        #expect(ImageDirectives.split("@image:\"/srv/a `b`.png\"").paths == ["/srv/a `b`.png"])
        #expect(ImageDirectives.split("@image:'/srv/a `b\" c.png'").paths == ["/srv/a `b\" c.png"])
    }

    @Test func onlyWholeDirectiveLinesAreImages() {
        let mid = "see @image:/x.png here"
        #expect(ImageDirectives.split(mid) == (mid, []))
        let spaced = "@image:/a b.png"  // unquoted with a space: not a directive Hermes writes
        #expect(ImageDirectives.split(spaced) == (spaced, []))
        #expect(ImageDirectives.split("@image:").paths.isEmpty)
        #expect(ImageDirectives.split("plain text") == ("plain text", []))
        #expect(ImageDirectives.split("@image:/only.png") == ("", ["/only.png"]))
    }

    @Test func storedUserRowsShowTheirImages() {
        var calls: StoredMessageProjection.ToolCalls = [:]
        let rows = [StoredMessage(id: 1, role: "user", content: "看这张图\n@image:/h/images/upload_1.png"),
                    StoredMessage(id: 2, role: "user", content: "@image:/h/images/upload_2.png")]
        let items = StoredMessageProjection.items(from: rows, toolCalls: &calls)
        #expect(items.map(\.text) == ["看这张图", ""])
        #expect(items.map { $0.images.map(\.path) } == [["/h/images/upload_1.png"], ["/h/images/upload_2.png"]])
        #expect(items.map { $0.images.map(\.name) } == [["upload_1.png"], ["upload_2.png"]])
    }

    @Test func snapshotMessagesShowTheirImagesToo() throws {
        let payload: JSONValue = [
            "session_id": "sid", "message_count": 1,
            "messages": [["role": "user", "text": "hi\n@image:/h/images/a.png"]],
        ]
        let transcript = Transcript(snapshot: try payload.decode(LiveSessionSnapshot.self))
        let first = try #require(transcript.items.first)
        #expect(first.text == "hi")
        #expect(first.images.map { $0.path } == ["/h/images/a.png"])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct GatewayMediaTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47])
    private static var dataURL: String { "data:image/png;base64,\(png.base64EncodedString())" }

    private func connector(_ http: RoutedHTTP) throws -> DashboardConnector {
        DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                           credential: .bearer(accessToken: "tok"), http: http)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func readsTheLaunchProfilesImagesThroughApiMedia() async throws {
        let http = RoutedHTTP { path, bearer in
            path == "/api/media" && bearer == "tok" ? (200, #"{"data_url":"\#(Self.dataURL)"}"#) : (500, "")
        }
        let data = try await connector(http).imageData(path: "/home/u/.hermes/images/upload_1.png", profile: nil)
        #expect(data == Self.png)
        #expect(http.requests.count == 1)
        #expect(query(http.requests[0]) == ["path": "/home/u/.hermes/images/upload_1.png"])
    }

    @Test func anotherProfilesUploadIsReadThroughTheFileRouteWithItsProfile() async throws {
        // `/api/media` serves only the dashboard's own HERMES_HOME (403 "Path outside media
        // roots", `files.py:342-344`); the upload is in the coder profile's home.
        let http = RoutedHTTP { path, _ in
            switch path {
            case "/api/media": return (403, #"{"detail":"Path outside media roots"}"#)
            case "/api/fs/read-data-url": return (200, #"{"dataUrl":"\#(Self.dataURL)"}"#)
            default: return (500, "")
            }
        }
        let path = "/home/u/.hermes/profiles/coder/images/upload_1.png"
        let data = try await connector(http).imageData(path: path, profile: "coder")
        #expect(data == Self.png)
        #expect(http.requests.map { $0.url?.path } == ["/api/media", "/api/fs/read-data-url"])
        #expect(query(http.requests[1]) == ["path": path, "profile": "coder"])
    }

    @Test(arguments: [404, 413])
    func otherFailuresAreThrown(_ status: Int) async throws {
        let http = RoutedHTTP { _, _ in (status, #"{"detail":"nope"}"#) }
        await #expect(throws: DashboardError.self) {
            _ = try await connector(http).imageData(path: "/h/images/gone.png", profile: nil)
        }
        #expect(http.requests.count == 1)  // no fallback: the file is gone or too large
    }

    @Test func dataURLs() {
        #expect(DataURL.decode(Self.dataURL) == Self.png)
        #expect(DataURL.decode("data:image/png,raw") == nil)
        #expect(DataURL.decode("https://x/y.png") == nil)
    }
}
