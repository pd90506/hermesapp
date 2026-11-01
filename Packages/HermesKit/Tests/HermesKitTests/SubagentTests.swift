import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

private func event(_ type: String, _ payload: JSONValue) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// A `subagent.*` payload as `_subagent_payload` builds it (`tui_gateway/tool_progress.py:457-486`).
private func payload(_ id: String, goal: String = "Read the docs", status: String? = nil,
                     tool: String? = nil, text: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = ["goal": .string(goal), "task_count": 2, "task_index": 0,
                                       "subagent_id": .string(id), "depth": 1, "model": "test-model"]
    if let status { object["status"] = .string(status) }
    if let tool { object["tool_name"] = .string(tool) }
    if let text { object["text"] = .string(text) }
    return .object(object.merging(extra) { $1 })
}

@Suite struct SubagentRosterTests {
    @Test func onlyAStartAddsARow() {
        var roster = SubagentRoster()
        roster.apply(event("subagent.tool", payload("a", tool: "web_search", text: "swift")))
        #expect(roster.runs.isEmpty)
        roster.apply(event("subagent.start", payload("a", status: "running")))
        roster.apply(event("subagent.tool", payload("a", tool: "web_search", text: "swift testing")))
        let run = try! #require(roster.live.first)
        #expect(run.goal == "Read the docs")
        #expect(run.currentTool == "web_search")
        #expect(run.activity.last?.text == #"Web Search("swift testing")"#)
        #expect(run.model == "test-model")
    }

    @Test func completionIsFinalAndThePromptAfterDropsIt() {
        var roster = SubagentRoster()
        roster.apply(event("subagent.start", payload("a", status: "running")))
        roster.apply(event("subagent.complete", payload("a", status: "completed", extra: ["summary": "Found 3 pages"])))
        #expect(roster.runs.first?.status == .completed)
        #expect(roster.runs.first?.activity.last == .init(kind: .summary, text: "Found 3 pages", isError: false))
        #expect(roster.runs.first?.currentTool == nil)
        #expect(roster.live.isEmpty)
        // A late frame never revives it.
        roster.apply(event("subagent.progress", payload("a", status: "running", text: "late")))
        #expect(roster.runs.first?.status == .completed)

        roster.pruneFinished()
        #expect(roster.runs.isEmpty)
        roster.apply(event("subagent.start", payload("a", status: "running")))
        #expect(roster.runs.isEmpty, "a dropped child never comes back")
    }

    @Test func statusesMapAsDesktops() {
        var roster = SubagentRoster()
        for (id, status) in [("t", "timeout"), ("c", "cancelled"), ("x", "weird")] {
            roster.apply(event("subagent.start", payload(id)))
            roster.apply(event("subagent.complete", payload(id, status: status, extra: ["duration_seconds": 612.3])))
        }
        #expect(roster.runs.map(\.status) == [.failed, .interrupted, .failed])
        #expect(roster.runs.first?.summary == "Timed out after 612s")
    }

    @Test func aSnapshotDropsGoneChildrenAndAddsListedOnes() {
        var roster = SubagentRoster()
        roster.apply(event("subagent.start", payload("gone", status: "running")))
        roster.apply(event("subagent.start", payload("done")))
        roster.apply(event("subagent.complete", payload("done", status: "completed")))
        // `_SUBAGENT_SNAPSHOT_FIELDS` (`methods_subagents.py:12-15`).
        roster.reconcile([
            ["subagent_id": "new", "parent_id": nil, "depth": 1, "goal": "Write tests", "delegation_id": "d1",
             "model": "m", "started_at": 1_761_900_000.0, "status": "running", "tool_count": 4,
             "last_tool": "read_file", "accepting_steer": true],
        ])
        #expect(roster.runs.map(\.id) == ["done", "new"])
        let new = try! #require(roster.live.first)
        #expect(new.startedAt == Date(timeIntervalSince1970: 1_761_900_000))
        #expect(new.toolCount == 4)
        #expect(new.activity.map(\.text) == ["Read File"])
    }

    @Test func activityKeepsTheNewestLines() {
        var roster = SubagentRoster()
        roster.apply(event("subagent.start", payload("a")))
        for index in 0..<30 {
            roster.apply(event("subagent.progress", payload("a", text: "step \(index)\n  done")))
        }
        roster.apply(event("subagent.progress", payload("a", text: "step 29 done")))
        let activity = try! #require(roster.runs.first?.activity)
        #expect(activity.count == 24)
        #expect(activity.last?.text == "step 29 done", "one line, and a repeat isn't added again")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatSubagentTests {
    private func open() async throws -> (ChatSession, ScriptedGateway, GatewayConnection) {
        let gateway = ScriptedGateway()
        gateway.on("session.resume", result: resumedPayload(sid: "sid-1", key: "stored-1"))
        gateway.on("subagent.list", result: ["subagents": [
            ["subagent_id": "a", "goal": "Read the docs", "status": "running", "started_at": 1_761_900_000.0],
        ], "delegations": []])
        gateway.on("subagent.steer") { params in
            .result(["status": "queued", "subagent_id": params["subagent_id"] ?? nil, "text": params["text"] ?? nil])
        }
        gateway.on("subagent.interrupt", result: ["found": true, "subagent_id": "a"])
        let connection = try await gateway.withDefaults().connect()
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        return (session, gateway, connection)
    }

    @Test func eventsAndTheRosterFillTheSubagents() async throws {
        let (session, gateway, connection) = try await open()
        defer { withExtendedLifetime(connection) {} }
        await session.refreshSubagents()
        #expect(session.subagents.live.map(\.id) == ["a"])
        #expect(gateway.params("subagent.list") == [["session_id": "sid-1"]])

        gateway.transport.sendEvent("subagent.tool", payload: payload("a", tool: "terminal", text: "ls"))
        #expect(await eventually { session.subagents.live.first?.currentTool == "terminal" })
        gateway.transport.sendEvent("subagent.complete", payload: payload("a", status: "completed"))
        #expect(await eventually { session.subagents.live.isEmpty })
        #expect(session.transcript.items.isEmpty, "subagent events stay out of the transcript")

        gateway.transport.sendEvent("message.start")
        #expect(await eventually { session.subagents.runs.isEmpty })
    }

    @Test func steerAndStopGoToTheChild() async throws {
        let (session, gateway, connection) = try await open()
        defer { withExtendedLifetime(connection) {} }
        #expect(try await session.steerSubagent("a", text: "  only the API docs "))
        #expect(gateway.params("subagent.steer") == [["session_id": "sid-1", "subagent_id": "a", "text": "only the API docs"]])
        #expect(try await session.stopSubagent("a"))
        #expect(gateway.params("subagent.interrupt") == [["session_id": "sid-1", "subagent_id": "a"]])
    }
}
