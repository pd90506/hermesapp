import Foundation
import HermesKit
import HermesProtocol
import Testing

@testable import HermesBridge

/// The chat's subagents, as the pill above the composer shows them: the `subagents`
/// snapshot follows the `subagent.*` events, and Steer and Stop call the gateway.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BridgeSubagentsTests {
    private func openedBridge(outbox: Outbox, server: BridgeServer) async throws -> Bridge {
        let bridge = try await Bridge.connected(server, outbox: outbox)
        try await Bridge.openedChat(bridge, outbox: outbox, server: server)
        return bridge
    }

    @Test func liveRunsFollowTheEventsAndCanBeSteeredAndStopped() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        server.on("subagent.steer") { _ in ["status": "queued"] }
        server.on("subagent.interrupt") { _ in ["found": true] }
        server.on("subagent.list") { _ in ["subagents": []] }
        let bridge = try await openedBridge(outbox: outbox, server: server)

        // A spawned child: the pill's rows appear.
        server.transport.sendEvent("subagent.start", sessionID: "rt-1", payload: [
            "subagent_id": "sa-1", "goal": "Find the failing test", "task_index": 0, "task_count": 2,
            "model": "test-model",
        ])
        #expect(await eventually {
            let runs = outbox.last("subagents")?["runs"] as? [[String: Any]] ?? []
            return runs.first?["goal"] as? String == "Find the failing test"
        })
        let run = try #require((outbox.last("subagents")?["runs"] as? [[String: Any]])?.first)
        #expect(run["id"] as? String == "sa-1")
        #expect(run["status"] as? String == "running")
        #expect(run["taskCount"] as? Int == 2)

        // What it does: its newest lines.
        server.transport.sendEvent("subagent.progress", sessionID: "rt-1", payload: [
            "subagent_id": "sa-1", "tool_name": "bash", "tool_preview": "swift test --filter X",
        ])
        #expect(await eventually {
            let runs = outbox.last("subagents")?["runs"] as? [[String: Any]] ?? []
            let activity = runs.first?["activity"] as? [[String: Any]] ?? []
            return activity.first?["kind"] as? String == "tool"
        })
        let activity = try #require((outbox.last("subagents")?["runs"] as? [[String: Any]])?.first?["activity"]
            as? [[String: Any]])
        #expect(activity.first?["text"] as? String == #"Bash("swift test --filter X")"#)

        try await bridge.receive(#"{"id":"g1","method":"steerSubagent","params":{"id":"sa-1","text":"run it again"}}"#)
        let steer = try #require(server.log.requests("subagent.steer").last)
        #expect(steer["params"]?["text"]?.stringValue == "run it again")
        #expect(steer["params"]?["subagent_id"]?.stringValue == "sa-1")

        try await bridge.receive(#"{"id":"g2","method":"stopSubagent","params":{"id":"sa-1"}}"#)
        let stop = try #require(server.log.requests("subagent.interrupt").last)
        #expect(stop["params"]?["subagent_id"]?.stringValue == "sa-1")
    }

    @Test func finishedRunsFallOffThePillAndReappearAsTheirNewestState() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server)
        server.transport.sendEvent("subagent.start", sessionID: "rt-1", payload: [
            "subagent_id": "sa-1", "goal": "Quick one",
        ])
        #expect(await eventually {
            (outbox.last("subagents")?["runs"] as? [[String: Any]])?.isEmpty == false
        })
        // A completed child is no longer live: the pill shows nothing.
        server.transport.sendEvent("subagent.complete", sessionID: "rt-1", payload: [
            "subagent_id": "sa-1", "status": "completed", "summary": "Done in 3s",
        ])
        #expect(await eventually {
            (outbox.last("subagents")?["runs"] as? [[String: Any]])?.isEmpty ?? false
        })
        _ = bridge
    }

    @Test func withoutAChatThereIsNothingToSteer() async throws {
        let outbox = Outbox()
        let bridge = try await Bridge.connected(BridgeServer(), outbox: outbox)
        try await bridge.receive(#"{"id":"g1","method":"steerSubagent","params":{"id":"sa-1","text":"hi"}}"#)
        #expect(outbox.last["error"] as? String == "no open chat")
    }
}
