import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct ClipboardColonTextTests {
    /// A single spreadsheet cell `TODO:fix` carries a picture of itself: it is text.
    @Test func aColonIsNotALink() {
        for text in ["TODO:fix", "key:value", "note:see above"] {
            #expect(ClipboardPolicy.decide(.init(types: ["public.utf8-plain-text", "public.tiff"], string: text)) == .text,
                    "\(text)")
        }
        #expect(ClipboardPolicy.decide(.init(types: ["public.tiff"], string: "file:///tmp/a.png")) == .imageData(type: "public.tiff"))
        #expect(ClipboardPolicy.decide(.init(types: ["public.png"], string: "HTTPS://x.example/a")) == .imageData(type: "public.png"))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ImageReadLimitsTests {
    @Test func aNonImagePathIsNotReadThroughTheFileRoute() async throws {
        let http = RoutedHTTP { _, _ in (403, #"{"detail":"Path outside media roots"}"#) }
        let connector = DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                                           credential: .bearer(accessToken: "tok"), http: http)
        await #expect(throws: DashboardError.self) {
            _ = try await connector.imageData(path: "/srv/logs/large.log", profile: "coder")
        }
        #expect(http.requests.map { $0.url?.path } == ["/api/media"])
    }

    @Test func hugeImagesAreNotDecoded() {
        #expect(TranscriptImage.mayDecode(width: 4000, height: 3000))
        #expect(TranscriptImage.mayDecode(width: 10_000, height: 10_000))
        #expect(!TranscriptImage.mayDecode(width: 30_000, height: 30_000))
        #expect(!TranscriptImage.mayDecode(width: Int.max, height: 2))
        #expect(TranscriptImage.mayDecode(width: nil, height: nil))
    }

    @Test func theLimiterRunsAFewAtATime() async {
        let limiter = AsyncLimiter(limit: 3)
        // A class, not a local `Mutex`: Swift 6.2 rejects a task-group closure that
        // captures a local noncopyable value by reference.
        final class Gauge: Sendable {
            let state = Mutex((now: 0, peak: 0))
        }
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await limiter.run {
                        gauge.state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                        try? await Task.sleep(for: .milliseconds(10))
                        gauge.state.withLock { $0.now -= 1 }
                    }
                }
            }
        }
        #expect(gauge.state.withLock { $0.peak } == 3)
        #expect(gauge.state.withLock { $0.now } == 0)
    }
}

@Suite struct TranscriptImageIDTests {
    @Test func thePathTwiceInOneMessageHasDistinctIDs() {
        var calls: StoredMessageProjection.ToolCalls = [:]
        let row = StoredMessage(id: 1, role: "user", content: "两张一样的\n@image:/h/images/a.png\n@image:/h/images/a.png")
        let images = StoredMessageProjection.items(from: [row], toolCalls: &calls).first?.images ?? []
        #expect(images.count == 2)
        #expect(Set(images.map(\.id)).count == 2)
    }

    @Test func theLiveBubbleAndTheStoredRowShareIDs() {
        let path = "/h/images/upload_1.png"
        let live = TranscriptImage(name: "a.png", path: path, localID: UUID(), position: 0)
        #expect(live.id == TranscriptImage.stored([path])[0].id)
    }
}
