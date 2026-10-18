import HermesKit
import HermesProtocol
import Testing

@Suite struct ToolRunTests {
    static func user(_ id: String, steer: Bool = false) -> TranscriptItem {
        var item = TranscriptItem(id: id, role: .user, text: "question")
        if steer { item.displayKind = "steer" }
        return item
    }

    static func reply(_ id: String, _ text: String, interim: Bool = false, active: Bool = false) -> TranscriptItem {
        var item = TranscriptItem(id: id, role: .assistant, text: text, isActive: active)
        item.isInterim = interim
        return item
    }

    static func tool(_ id: String, _ name: String, args: JSONValue? = nil, context: String? = nil,
                     phase: ToolActivity.Phase = .complete) -> TranscriptItem {
        var item = TranscriptItem(id: id, role: .tool, text: "", isActive: phase == .running)
        item.toolName = name
        item.detail = context
        var activity = ToolActivity(toolID: id, name: name, phase: phase)
        activity.args = args
        activity.context = context
        item.tool = activity
        return item
    }

    static func kinds(_ blocks: [TranscriptBlock]) -> [String] {
        blocks.map {
            switch $0 {
            case .item(let item): item.id
            case .run(let run): "[" + run.items.map(\.id).joined(separator: ",") + (run.isLive ? "*" : "") + "]"
            }
        }
    }

    // MARK: Grouping

    /// Desktop groups a message's adjacent tool parts (`ToolGroupSlot`): commentary or
    /// reasoning between calls ends a run, settled or live alike.
    @Test func settledTurnGroupsOnlyConsecutiveToolCalls() {
        var thinking = Self.reply("r1", "")
        thinking.reasoning = "Which file next?"
        let items = [
            Self.user("u1"),
            Self.reply("a1", "Let me look.", interim: true),
            Self.tool("t1", "terminal", args: ["command": "ls"]),
            Self.tool("t2", "read_file", args: ["path": "a.md"]),
            Self.reply("a2", "Now the image.", interim: true),
            Self.tool("t3", "vision_analyze"),
            thinking,
            Self.tool("t4", "read_file", args: ["path": "b.md"]),
            Self.reply("a3", "| a | b |\n|---|---|\n| 1 | 2 |"),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: false)
        #expect(Self.kinds(blocks) == ["u1", "a1", "[t1,t2]", "a2", "[t3]", "r1", "[t4]", "a3"])
    }

    @Test func runningTurnGroupsOnlyConsecutiveToolCalls() {
        let items = [
            Self.user("u1"), Self.reply("old", "Earlier."), Self.user("u2"),
            Self.tool("t1", "terminal"), Self.tool("t2", "read_file"),
            Self.reply("a1", "Interim note.", interim: true),
            Self.tool("t3", "terminal", phase: .running),
            Self.reply("blank", ""),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: true)
        #expect(Self.kinds(blocks) == ["u1", "old", "u2", "[t1,t2]", "a1", "[t3*]", "blank"])
    }

    @Test func aRunIsNoLongerLiveOnceTextFollowsIt() {
        let items = [Self.user("u1"), Self.tool("t1", "terminal"), Self.reply("a1", "Streaming…", active: true)]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: true)) == ["u1", "[t1]", "a1"])
    }

    @Test func turnEndingWithToolsKeepsItsRunsAndCommentary() {
        let items = [Self.user("u1"), Self.reply("a1", "Trying."), Self.tool("t1", "terminal"), Self.tool("t2", "terminal")]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: false)) == ["u1", "a1", "[t1,t2]"])
    }

    @Test func steerAndSystemRowsKeepTheirPlaces() {
        let items = [
            Self.user("u1"), Self.tool("t1", "terminal"), Self.user("s1", steer: true),
            TranscriptItem(id: "sys", role: .system, text: "note"), Self.tool("t2", "terminal"), Self.reply("a1", "Done."),
        ]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: false)) == ["u1", "[t1]", "s1", "sys", "[t2]", "a1"])
    }

    @Test func fileEditsAndCardsStayOutOfTheSummary() {
        let items = [
            Self.user("u1"), Self.tool("t1", "read_file"), Self.tool("e1", "patch"),
            Self.tool("t2", "terminal"), Self.tool("d1", "delegate_task"), Self.tool("t3", "terminal"),
            Self.reply("a1", "Done."),
        ]
        let expected = ["u1", "[t1]", "e1", "[t2]", "d1", "[t3]", "a1"]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: false)) == expected)
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: true)) == expected)
    }

    @Test func diffsComeFromTheEventOrTheStoredResult() {
        var live = Self.tool("e1", "patch")
        live.tool?.inlineDiff = "\u{1B}[33m┊ review diff\n--- a/x\n+++ b/x\n-old\n+new\u{1B}[0m"
        #expect(live.toolDiff == "--- a/x\n+++ b/x\n-old\n+new")
        var stored = Self.tool("e2", "patch")
        stored.tool?.output = #"{"success": true, "diff": "-a\n+b"}"#
        #expect(stored.toolDiff == "-a\n+b")
        #expect(Self.tool("t", "terminal").toolDiff == nil)
    }

    @Test func diffBoxesDropHeaders() {
        let diff = "diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new"
        #expect(ToolCallSummary.displayDiff(diff) == " keep\n-old\n+new")
    }

    /// The chat keeps its place across an older page by a row: the page can hold the
    /// start of the run the top row is in, which renames that run.
    @Test func aRowsBlockIsFoundAfterAnOlderPageRenamesItsRun() {
        let loaded = [
            Self.tool("t2", "terminal"), Self.reply("a2", "Done."),
            Self.user("u2"), Self.reply("b1", "Plain answer."),
        ]
        let before = TranscriptGrouping.blocks(loaded, isRunning: false)
        #expect(Self.kinds(before) == ["[t2]", "a2", "u2", "b1"])
        #expect(TranscriptGrouping.blockID(containing: "t2", in: before) == "run-t2")

        let older = [Self.user("u1"), Self.reply("a1", "Checking."), Self.tool("t1", "terminal")]
        let after = TranscriptGrouping.blocks(older + loaded, isRunning: false)
        #expect(Self.kinds(after) == ["u1", "a1", "[t1,t2]", "a2", "u2", "b1"])
        #expect(TranscriptGrouping.blockID(containing: "t2", in: after) == "run-t1")
        #expect(TranscriptGrouping.blockID(containing: "u2", in: after) == "u2")
        #expect(TranscriptGrouping.blockID(containing: "gone", in: after) == nil)
    }

    // MARK: Summaries

    @Test func summaryMatchesDesktopWording() {
        let tools = [
            Self.tool("t1", "vision_analyze"),
            Self.tool("t2", "terminal", args: ["command": "ls"]),
            Self.tool("t3", "terminal", args: ["command": "pwd"]),
        ]
        #expect(ToolCallSummary.run(tools, live: false) == "Analyzed 1 image, ran 2 commands")
    }

    @Test func singleTargetsAreNamed() {
        let edit = Self.tool("t1", "patch", args: ["path": "/repo/Sources/Transcript.swift"])
        let search = Self.tool("t2", "web_search", args: ["query": "swift grid"])
        let skill = Self.tool("t3", "skill_view", args: ["name": "swiftui"])
        #expect(ToolCallSummary.run([skill, edit, search], live: false)
            == "Loaded skill: swiftui, edited Transcript.swift, searched “swift grid”")
    }

    @Test func liveCategorySpeaksInThePresentTense() {
        let tools = [
            Self.tool("t1", "read_file", args: ["path": "a.swift"]),
            Self.tool("t2", "terminal", args: ["command": "cd /repo && swift build 2>&1 | tail -20"], phase: .running),
        ]
        #expect(ToolCallSummary.run(tools, live: true) == "Explored a.swift, running swift build")
    }

    @Test func failuresAreCounted() {
        let tools = [Self.tool("t1", "terminal", phase: .failed), Self.tool("t2", "terminal")]
        #expect(ToolCallSummary.run(tools, live: false) == "Ran 2 commands, 1 tool call failed")
    }

    @Test func rowTitles() {
        func title(_ item: TranscriptItem, result: JSONValue? = ["output": "", "exit_code": 0]) -> String {
            var item = item
            item.tool?.result = result
            return ToolCallView(item).title
        }
        #expect(title(Self.tool("t", "terminal", args: ["command": "git status"])) == "Ran git status")
        #expect(title(Self.tool("t", "terminal", context: "make test")) == "Ran make test")
        #expect(title(Self.tool("t", "memory"), result: ["success": true]) == "Saved to memory")
        #expect(title(Self.tool("t", "read_file", args: .string("{\"path\":\"x/y.md\"}")), result: ["content": "1|a"])
            == "Read y.md")
        #expect(title(Self.tool("t", "web_extract", args: ["urls": ["https://example.com/docs"]]), result: ["results": []])
            == "Read example.com/docs")
        #expect(title(Self.tool("t", "terminal", args: ["command": "ls"]), result: nil) == "Result unavailable")
        #expect(title(Self.tool("t", "terminal", args: ["command": "ls"], phase: .running), result: nil) == "Running ls")
    }

    @Test func shellCommandsLoseTheirPlumbing() {
        #expect(ToolCallSummary.summarizeShellCommand("cd /x && FOO=1 make 2>&1 | tail -5") == "FOO=1 make")
        #expect(ToolCallSummary.summarizeShellCommand("ls -la") == "ls -la")
        #expect(ToolCallSummary.summarizeShellCommand("git add . && git commit -m 'a && b'; echo \"--done--\"")
            == "git add . + 1 command")
    }
}
