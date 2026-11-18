import Foundation
import HermesKit
import HermesProtocol
import Testing

@testable import HermesBridge

/// The transcript's blocks and tool calls as the bridge sends them (docs/desktop-bridge.md,
/// "Transcript"): HermesKit's grouping, unchanged, in the wire's shape.
@Suite struct TranscriptWireTests {
    static func tool(_ id: String, _ name: String, args: JSONValue? = nil, result: String? = nil,
                     phase: ToolActivity.Phase = .complete) -> TranscriptItem {
        var item = TranscriptItem(id: id, role: .tool, text: "", isActive: phase == .running)
        item.toolName = name
        var activity = ToolActivity(toolID: id, name: name, phase: phase)
        activity.args = args
        activity.output = result
        item.tool = activity
        return item
    }

    static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aTurnsStepsComeAsWorkWithItsGroupsAndSteps() throws {
        let items = [
            TranscriptItem(id: "u1", role: .user, text: "Check the build"),
            Self.tool("t1", "terminal", args: .object(["command": .string("git status")]),
                      result: #"{"output": "clean", "exit_code": 0}"#),
            TranscriptItem(id: "a1", role: .assistant, text: "All clean."),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: false).map(TranscriptWire.Block.init)
        #expect(blocks.map(\.kind) == ["item", "work", "item"])
        #expect(blocks[0].item == "u1")
        #expect(blocks[2].item == "a1")
        let work = try #require(blocks[1].work)
        #expect(!work.isLive)
        #expect(work.title == "Completed")
        let group = try #require(work.entries.first?.group)
        #expect(work.entries.first?.kind == "group")
        #expect(group.iconTool == "terminal")
        let step = try #require(group.steps.first)
        #expect(step.kind == "tool")
        #expect(step.item == "t1")
        #expect(step.summary == "git status")
        let wire = try Self.json(blocks[1])
        #expect((wire["work"] as? [String: Any])?["entries"] != nil)
    }

    @Test func aToolCallComesAsItsViewDrawsIt() throws {
        let item = Self.tool("t1", "terminal", args: .object(["command": .string("ls")]),
                             result: #"{"output": "\u001B[32ma.txt\u001B[0m", "exit_code": 2}"#)
        let tool = TranscriptWire.Tool(ToolCallView(item))
        #expect(tool.toolName == "terminal")
        #expect(tool.terminalCommand == "ls")
        #expect(tool.terminalExitCode == 2)
        #expect(tool.isExpandable)
        #expect(!tool.detail.contains("\u{1B}"))
    }

    @Test func aDiffComesInItsDisplayFormWithItsCounts() {
        var item = Self.tool("e1", "patch")
        item.tool?.inlineDiff = "--- a/x\n+++ b/x\n-old\n+new\n+more"
        let tool = TranscriptWire.Tool(ToolCallView(item))
        #expect(tool.added == 2)
        #expect(tool.removed == 1)
        #expect(tool.opensByDefault)
        #expect(!tool.inlineDiff.isEmpty)
    }

    @Test func aRunningTurnIsLive() throws {
        let items = [
            TranscriptItem(id: "u1", role: .user, text: "go"),
            Self.tool("t1", "read_file", args: .object(["path": .string("notes.md")]), phase: .running),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: true).map(TranscriptWire.Block.init)
        let work = try #require(blocks.last?.work)
        #expect(work.isLive)
        #expect(work.entries.first?.group?.isLive == true)
        #expect(work.entries.first?.group?.steps.first?.isLive == true)
    }
}
