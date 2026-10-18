import HermesProtocol
import Testing

@testable import HermesKit

/// Each tool call reads as Desktop's `buildToolView` draws it
/// (`apps/desktop/src/components/assistant-ui/tool/fallback-model/index.ts`).
@Suite struct ToolCallViewTests {
    static func call(_ name: String, args: JSONValue? = nil, result: JSONValue? = nil,
                     phase: ToolActivity.Phase = .complete, error: String? = nil) -> TranscriptItem {
        var item = TranscriptItem(id: "t", role: .tool, text: "", isActive: phase == .running)
        item.toolName = name
        var tool = ToolActivity(toolID: "t", name: name, phase: phase)
        tool.args = args
        tool.result = result
        tool.error = error
        item.tool = tool
        return item
    }

    static let path = "/home/u/papers/2026-wiechman-institutional-system-robustness.md"

    @Test func aReadNamesItsFileAndLinesAndOpensToThem() {
        let content = "237|To address the limitations\n238|Institutional costs, flexibility, and\n259|end"
        let view = ToolCallView(Self.call("read_file", args: ["path": .string(Self.path), "offset": 237, "limit": 23],
                                          result: ["content": .string(content), "total_lines": 400]))
        #expect(view.title == "Read 2026-wiechman-institutional-system-robustness.md L237-259")
        #expect(view.status == .success && view.isExpandable && view.showsDetail && view.rendersDetailAsCode)
        #expect(view.detail == content)
        #expect(!view.opensByDefault)
    }

    @Test func aReadWithoutAnOffsetTakesItsLinesFromTheContent() {
        let view = ToolCallView(Self.call("read_file", args: ["path": "a/notes.md", "limit": 50],
                                          result: ["content": "1|# Notes\n2|\n3|end"]))
        #expect(view.title == "Read notes.md L1-3")
        let whole = ToolCallView(Self.call("read_file", args: ["path": "a/notes.md"], result: ["content": "1|x"]))
        #expect(whole.title == "Read notes.md")
    }

    /// A stored row's content is its result, so a reopened chat shows the same card.
    @Test func aStoredReadKeepsItsResult() throws {
        var calls: StoredMessageProjection.ToolCalls = [:]
        var assistant = StoredMessage(id: 1, role: "assistant", content: .string(""))
        assistant.toolCalls = [["id": "call_1", "function": [
            "name": "read_file", "arguments": .string(#"{"path":"\#(Self.path)","offset":237,"limit":23}"#),
        ]]]
        var row = StoredMessage(id: 2, role: "tool", content: .string(#"{"content": "237|To address", "total_lines": 400}"#))
        row.toolCallID = "call_1"
        let items = StoredMessageProjection.items(from: [assistant, row], toolCalls: &calls)
        let tool = try #require(items.first)
        let view = ToolCallView(tool)
        #expect(view.title == "Read 2026-wiechman-institutional-system-robustness.md L237-259")
        #expect(view.detail == "237|To address" && view.showsDetail)
    }

    @Test func aCommandShowsItsPromptExitCodeAndOutput() {
        let view = ToolCallView(Self.call("terminal", args: ["command": "cd /repo && git status 2>&1 | tail -5"],
                                          result: ["output": "On branch main\nnothing to commit", "exit_code": 0]))
        #expect(view.title == "Ran git status")
        #expect(view.terminalCommand == "cd /repo && git status 2>&1 | tail -5" && view.terminalExitCode == 0)
        #expect(view.detail == "On branch main\nnothing to commit" && view.showsDetail && view.rendersDetailAsCode)
        let running = ToolCallView(Self.call("terminal", args: ["command": "make"], phase: .running))
        #expect(running.title == "Running make" && running.status == .running && running.isPending)
    }

    @Test func anExitCodeWithoutOutputIsANoticeOrAnError() {
        let one = ToolCallView(Self.call("terminal", args: ["command": "grep x f"], result: ["output": "", "exit_code": 1]))
        #expect(one.status == .notice && one.detail == "Command failed with exit code 1." && one.showsDetail)
        let two = ToolCallView(Self.call("terminal", args: ["command": "false"], result: ["output": "", "exit_code": 2]))
        #expect(two.status == .error && two.errorSummary == "Command failed with exit code 2.")
        let quiet = ToolCallView(Self.call("terminal", args: ["command": "grep x f"], result: ["output": "x", "exit_code": 1]))
        #expect(quiet.status == .success)
    }

    @Test func aSearchListsItsHitsAndCountsThem() {
        let result: JSONValue = ["data": ["web": [
            ["title": "Swift Grid", "url": "https://example.com/grid", "description": "Lay out views[1]."],
            ["title": "Docs", "url": "https://example.com/docs"],
        ]]]
        let view = ToolCallView(Self.call("web_search", args: ["query": "swift grid"], result: result))
        #expect(view.title == "Searched “swift grid”")
        #expect(view.countLabel == "2 results" && view.searchQuery == "swift grid")
        #expect(view.searchHits.map(\.title) == ["Swift Grid", "Docs"])
        #expect(view.searchHits[0].snippet == "Lay out views.")
        #expect(view.isExpandable)
    }

    @Test func aFailedCallOpensToItsError() {
        let view = ToolCallView(Self.call("web_extract", args: ["urls": ["https://example.com/a"]],
                                          result: ["success": false, "error": "403 Forbidden"], phase: .failed))
        #expect(view.status == .error && view.errorSummary == "403 Forbidden" && view.showsDetail)
        #expect(view.detailLabel == "Error details")
        let missing = ToolCallView(Self.call("read_file", args: ["path": "x.md"],
                                             result: ["error": "File not found: x.md"]))
        #expect(missing.status == .notice && missing.title == "Read x.md")
    }

    @Test func editsOpenToTheirDiffAndDiffLessOnesHide() {
        var patch = Self.call("patch", args: ["path": "Sources/A.swift"], result: ["success": true])
        patch.tool?.inlineDiff = "--- a/A.swift\n+++ b/A.swift\n-old\n+new"
        let view = ToolCallView(patch)
        #expect(view.title == "A.swift" && view.opensByDefault && !view.showsDetail && !view.isHidden)
        let created = ToolCallView(Self.call("write_file", args: ["path": "B.md"], result: ["bytes_written": 3]))
        #expect(created.isHidden)
        let running = ToolCallView(Self.call("write_file", args: ["path": "B.md"], phase: .running))
        #expect(!running.isHidden && running.title == "B.md")
    }

    @Test func otherToolsShowASummaryOfTheirResult() {
        let view = ToolCallView(Self.call("custom_lookup", args: ["id": 7], result: ["path": "notes.md", "bytes": 12]))
        #expect(view.title == "Custom Lookup")
        #expect(view.detail == "- Path: notes.md\n- Bytes: 12")
        #expect(ToolCallView(Self.call("browser_scroll", result: ["ok": true])).title == "Browser Scroll")
        #expect(ToolCallView(Self.call("memory", result: ["success": true, "message": "Saved."])).title == "Saved to memory")
    }

    @Test func skillsReadAsSkillActivity() {
        let view = ToolCallView(Self.call("skill_view", args: ["name": "swiftui"], result: ["success": true]))
        #expect(view.title == "Loaded skill: swiftui")
    }

    @Test func aCallThatEndedWithoutAResultSaysSo() {
        let view = ToolCallView(Self.call("terminal", args: ["command": "sleep 99"]))
        #expect(view.title == "Result unavailable" && view.status == .warning)
    }

    @Test func resultSummariesMatchDesktop() {
        #expect(ToolResultText.summary(["message": "Done."]) == "Done.")
        #expect(ToolResultText.summary(["data": ["items": ["a", "b"]]]) == "- Items: a, b")
        #expect(ToolResultText.summary(.array(["x", "y"])) == "- x\n- y")
        #expect(ToolResultText.errorMessage(["error": "boom"]) == "boom")
        #expect(ToolResultText.errorMessage(["error": .null, "output": "error: not really"]) == "")
        #expect(ToolResultText.errorMessage(["success": false, "data": ["error": "nope"]]) == "nope")
    }
}
