import Foundation
import HermesKit
import HermesProtocol
import Testing

@testable import HermesBridge

/// The chat's context gauge and session counters (`refreshUsage`, the `usage`
/// snapshot), as the composer's ring shows them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BridgeUsageTests {
    @Test func refreshUsageReadsTheGaugeAndTheBreakdown() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        server.on("session.usage") { _ in [
            "total": 120, "input": 90, "output": 30, "calls": 2, "reasoning": 10,
            "context_used": 5_000, "context_max": 200_000, "context_percent": 3,
            "context_estimated": false, "cache_hit_pct": 80, "avg_tps": 42.5, "cost_usd": 0.01,
            "model": "test-model",
        ] }
        server.on("session.context_breakdown") { _ in [
            "context_max": 200_000, "context_used": 6_000, "context_percent": 3,
            "context_estimated": true, "model": "test-model",
            "categories": [
                ["id": "system", "label": "System prompt", "tokens": 1_200],
                ["id": "messages", "label": "Messages", "tokens": 2_800],
            ],
        ] }
        let bridge = try await Bridge.connected(server, outbox: outbox)
        try await Bridge.openedChat(bridge, outbox: outbox, server: server)
        try await bridge.receive(#"{"id":"u1","method":"refreshUsage"}"#)
        #expect(await eventually {
            let gauge = outbox.last("usage")?["gauge"] as? [String: Any]
            return gauge?["used"] as? Int == 6_000
        })

        let usage = try #require(outbox.last("usage"))
        #expect(usage["sessionID"] as? String == "rt-1")
        // A free chat takes its gauge from the breakdown (the measured occupancy).
        let gauge = try #require(usage["gauge"] as? [String: Any])
        #expect(gauge["used"] as? Int == 6_000)
        #expect(gauge["max"] as? Int == 200_000)
        #expect(gauge["percent"] as? Int == 3)
        #expect(gauge["isEstimated"] as? Bool == true)
        let breakdown = try #require(usage["breakdown"] as? [String: Any])
        let categories = try #require(breakdown["categories"] as? [[String: Any]])
        #expect(categories.map { $0["label"] as? String } == ["System prompt", "Messages"])
        let counters = try #require(usage["usage"] as? [String: Any])
        #expect(counters["total"] as? Int == 120)
        #expect(counters["calls"] as? Int == 2)
        #expect(counters["cacheHitPercent"] as? Int == 80)
        #expect(counters["tokensPerSecond"] as? Double == 42.5)
        // Both calls went out with the chat's runtime id.
        #expect(server.log.requests("session.usage").first?["params"]?["session_id"]?.stringValue == "rt-1")
        #expect(server.log.requests("session.context_breakdown").first?["params"]?["session_id"]?.stringValue == "rt-1")
    }

    @Test func aChatWithNoNumbersYetHasNoGauge() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        server.on("session.usage") { _ in ["total": 0, "calls": 0] }
        server.on("session.context_breakdown") { _ in ["context_max": 0] }
        let bridge = try await Bridge.connected(server, outbox: outbox)
        try await Bridge.openedChat(bridge, outbox: outbox, server: server)
        try await bridge.receive(#"{"id":"u1","method":"refreshUsage"}"#)
        #expect(await eventually { outbox.last("usage")?["usage"] != nil })
        let usage = try #require(outbox.last("usage"))
        #expect(usage["gauge"] == nil)
        #expect(usage["breakdown"] == nil)
    }
}
