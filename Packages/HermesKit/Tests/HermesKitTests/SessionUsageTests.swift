import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// `_get_usage` with a measured context (`tui_gateway/server.py:1389-1438`,
/// `agent/context_breakdown.py:130-140`).
private let measured: JSONValue = [
    "model": "test-model", "input": 12_000, "output": 800, "reasoning": 0, "prompt": 12_000, "completion": 800,
    "total": 12_800, "calls": 3, "context_used": 30_000, "context_max": 200_000, "context_percent": 15,
    "context_source": "provider_usage", "context_estimated": false, "compressions": 0, "cache_hit_pct": 62,
    "avg_latency_s": 2.1, "avg_tps": 48.4, "active_subagents": 0,
]

/// `compute_session_context_breakdown`'s answer, trimmed (`agent/context_breakdown.py:143-230`).
private let breakdown: JSONValue = [
    "categories": [
        ["id": "system_prompt", "label": "System prompt", "tokens": 4_000, "color": "#888"],
        ["id": "tool_definitions", "label": "Tool definitions", "tokens": 9_000, "color": "#999"],
        ["id": "messages", "label": "Messages", "tokens": 0, "color": "#aaa"],
    ],
    "context_max": 200_000, "context_percent": 7, "context_used": 13_000, "estimated_total": 13_000,
    "context_estimated": true, "context_source": "estimate", "model": "test-model",
]

@Suite struct SessionUsageTests {
    @Test func readsTheGatewaysUsage() throws {
        let usage = try #require(SessionUsage(measured))
        #expect(usage.total == 12_800)
        #expect(usage.calls == 3)
        #expect(usage.contextMax == 200_000)
        #expect(usage.contextPercent == 15)
        #expect(!usage.contextEstimated)
        #expect(usage.cacheHitPercent == 62)
        #expect(usage.tokensPerSecond == 48.4)
        #expect(SessionUsage(["calls": 0, "input": 0, "output": 0, "total": 0])?.contextMax == nil)
        #expect(SessionUsage([:]) == nil)
        #expect(SessionUsage("nope") == nil)
    }

    @Test func aReportWithoutContextKeepsTheLastOccupancy() throws {
        let first = try #require(SessionUsage(measured))
        let later = try #require(SessionUsage(["total": 20_000, "calls": 4]))
        let merged = first.merged(with: later)
        #expect(merged.total == 20_000)
        #expect(merged.contextUsed == 30_000)
        #expect(merged.contextMax == 200_000)
    }

    @Test func breakdownSkipsEmptyCategoriesAndZeroedAnswers() throws {
        let read = try #require(ContextBreakdown(breakdown))
        #expect(read.categories.map(\.id) == ["system_prompt", "tool_definitions"])
        #expect(read.contextUsed == 13_000)
        #expect(read.contextEstimated)
        #expect(ContextBreakdown(["categories": [], "context_max": 0, "context_used": 0]) == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatUsageTests {
    @Test func usageAndBreakdownFeedTheGauge() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.resume", result: resumedPayload(sid: "sid-1", key: "stored-1"))
        gateway.on("session.usage", result: ["calls": 0, "input": 0, "output": 0, "total": 0])
        gateway.on("session.context_breakdown", result: breakdown)
        let connection = try await gateway.withDefaults().connect()
        let session = try await connection.open(SessionSummary(id: "stored-1"))

        // A resumed chat: no measured context, so the breakdown's estimate.
        await session.refreshUsage()
        #expect(gateway.params("session.context_breakdown") == [["session_id": "sid-1"]])
        #expect(session.contextGauge == ContextGauge(used: 13_000, max: 200_000, percent: 7, isEstimated: true))

        // A turn measures it: the streamed usage wins over the older breakdown.
        gateway.transport.sendEvent("message.start")
        gateway.transport.sendEvent("message.complete", payload: ["text": "done", "status": "complete", "usage": measured])
        #expect(await eventually { session.usage?.total == 12_800 })
        #expect(session.contextGauge == ContextGauge(used: 30_000, max: 200_000, percent: 15, isEstimated: false))

        // `session.usage` events update the counters, not the occupancy.
        gateway.transport.sendEvent("session.usage", payload: ["usage": ["total": 13_500, "calls": 4]])
        #expect(await eventually { session.usage?.total == 13_500 })
        #expect(session.contextGauge?.used == 30_000)
        withExtendedLifetime(connection) {}
    }
}
