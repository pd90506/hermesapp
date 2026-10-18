import Foundation
@testable import HermesKit
import HermesProtocol
import Testing

@Suite struct TurnWorkTests {
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
            case .work(let work): "work(" + work.entries.map(entry).joined(separator: " ") + ")" + (work.isLive ? "*" : "")
            }
        }
    }

    static func entry(_ entry: TurnWork.Entry) -> String {
        switch entry {
        case .commentary(let item): "c:" + item.id
        case .card(let item): "card:" + item.id
        case .group(let group):
            "[" + group.steps.map { step in
                if case .think(let item) = step { "~" + item.id } else { step.id }
            }.joined(separator: ",") + "]" + (group.isLive ? "*" : "")
        }
    }

    static func work(_ blocks: [TranscriptBlock]) -> [TurnWork] {
        blocks.compactMap { if case .work(let work) = $0 { work } else { nil } }
    }

    static func at(_ seconds: Double, _ item: TranscriptItem) -> TranscriptItem {
        var item = item
        item.timestamp = Date(timeIntervalSince1970: seconds)
        return item
    }

    // MARK: Grouping

    /// Everything before the answer is one block: commentary between groups of steps,
    /// each row's reasoning a step beside its calls, the answer's reasoning the last step.
    @Test func settledTurnFoldsItsWorkBeforeTheAnswer() throws {
        var looking = Self.reply("a1", "Let me look.", interim: true)
        looking.reasoning = "Plan the search."
        var thinking = Self.reply("r1", "")
        thinking.reasoning = "Which file next?"
        var answer = Self.reply("a3", "| a | b |\n|---|---|\n| 1 | 2 |")
        answer.reasoning = "All read."
        let items = [
            Self.user("u1"), looking,
            Self.tool("t1", "terminal", args: ["command": "ls"]),
            Self.tool("t2", "read_file", args: ["path": "a.md"]),
            Self.reply("a2", "Now the image.", interim: true),
            Self.tool("t3", "vision_analyze"),
            thinking,
            Self.tool("t4", "read_file", args: ["path": "b.md"]),
            answer,
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: false)
        #expect(Self.kinds(blocks) == ["u1", "work(c:a1 [~a1,t1,t2] c:a2 [t3,~r1,t4,~a3])", "a3"])
        let work = try #require(Self.work(blocks).first)
        #expect(work.items.map(\.id) == ["a1", "t1", "t2", "a2", "t3", "r1", "t4"])
        #expect(blocks.last?.items.first?.reasoning == "", "the answer's reasoning is drawn as a step")
        if case .commentary(let commentary) = work.entries[0] { #expect(commentary.reasoning.isEmpty) }
    }

    @Test func aPlainAnswerHasNoWork() {
        var reasoned = Self.reply("b1", "Answer.")
        reasoned.reasoning = "Easy."
        let items = [Self.user("u1"), Self.reply("a1", "Plain."), Self.user("u2"), reasoned]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: false)) == ["u1", "a1", "u2", "work([~b1])", "b1"])
        #expect(TranscriptGrouping.blocks(items, isRunning: false)[3].id == "work-b1")
    }

    @Test func runningTurnShowsItsWorkLive() {
        let items = [
            Self.user("u1"), Self.reply("old", "Earlier."), Self.user("u2"),
            Self.tool("t1", "terminal"), Self.tool("t2", "read_file"),
            Self.reply("a1", "Interim note.", interim: true),
            Self.tool("t3", "terminal", phase: .running),
            Self.reply("blank", ""),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: true)
        #expect(Self.kinds(blocks) == ["u1", "old", "u2", "work([t1,t2] c:a1 [t3]*)*"])
        #expect(Self.work(blocks).first?.items.last?.id == "blank")
    }

    @Test func workIsNoLongerLiveOnceTheAnswerStreams() {
        let items = [Self.user("u1"), Self.tool("t1", "terminal"), Self.reply("a1", "Streaming…", active: true)]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: true)) == ["u1", "work([t1])", "a1"])
    }

    @Test func aTurnEndingWithToolsIsAllWork() {
        let items = [Self.user("u1"), Self.reply("a1", "Trying."), Self.tool("t1", "terminal"), Self.tool("t2", "terminal")]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: false)) == ["u1", "work(c:a1 [t1,t2])"])
    }

    @Test func steerAndSystemRowsKeepTheirPlaces() {
        let items = [
            Self.user("u1"), Self.tool("t1", "terminal"), Self.user("s1", steer: true),
            TranscriptItem(id: "sys", role: .system, text: "note"), Self.tool("t2", "terminal"), Self.reply("a1", "Done."),
        ]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: false))
            == ["u1", "work([t1])", "s1", "sys", "work([t2])", "a1"])
    }

    @Test func cardsKeepTheirRowsAndEditsAreSteps() {
        let items = [
            Self.user("u1"), Self.tool("t1", "read_file"), Self.tool("e1", "patch"),
            Self.tool("t2", "terminal"), Self.tool("d1", "delegate_task"), Self.tool("t3", "terminal"),
            Self.reply("a1", "Done."),
        ]
        let expected = ["u1", "work([t1,e1,t2] card:d1 [t3])", "a1"]
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: false)) == expected)
        #expect(Self.kinds(TranscriptGrouping.blocks(items, isRunning: true)) == expected)
    }

    /// Stored rows carry their time: the work lasts from the prompt to the answer.
    @Test func workIsTimedFromThePromptToTheAnswer() throws {
        let items = [Self.at(100, Self.user("u1")), Self.at(110, Self.tool("t1", "terminal")),
                     Self.at(145, Self.reply("a1", "Done."))]
        let work = try #require(Self.work(TranscriptGrouping.blocks(items, isRunning: false)).first)
        #expect(work.duration == 45)
        #expect(TurnWork.settledTitle(duration: work.duration, interrupted: false) == "Completed in 45s")
        #expect(TurnWork.settledTitle(duration: 65, interrupted: true) == "Stopped after 1m 05s")
        #expect(TurnWork.settledTitle(duration: nil, interrupted: false) == "Completed")

        let unanswered = [Self.at(100, Self.user("u1")), Self.at(130, Self.tool("t1", "terminal"))]
        #expect(Self.work(TranscriptGrouping.blocks(unanswered, isRunning: false)).first?.duration == 30)
        let live = Self.work(TranscriptGrouping.blocks(unanswered, isRunning: true)).first
        #expect(live?.isLive == true)
        #expect(live?.endedAt == nil, "a live turn has not ended")
        #expect(live?.startedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func storedRowsAndSentPromptsCarryTheirTime() {
        var row = StoredMessage(id: 7, role: "user", content: "hi")
        row.timestamp = 1_700_000_000
        var calls = StoredMessageProjection.ToolCalls()
        let items = StoredMessageProjection.items(from: [row], toolCalls: &calls)
        #expect(items.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))

        var transcript = Transcript()
        let sent = Date(timeIntervalSince1970: 42)
        let id = transcript.appendUserPrompt("hello", sentAt: sent)
        #expect(transcript.items.first { $0.id == id }?.timestamp == sent)
    }

    /// The chat keeps its place across an older page by a row: the page can hold the
    /// start of the work the top row is in, which renames that work.
    @Test func aRowsBlockIsFoundAfterAnOlderPageRenamesItsWork() {
        let loaded = [
            Self.tool("t2", "terminal"), Self.reply("a2", "Done."),
            Self.user("u2"), Self.reply("b1", "Plain answer."),
        ]
        let before = TranscriptGrouping.blocks(loaded, isRunning: false)
        #expect(Self.kinds(before) == ["work([t2])", "a2", "u2", "b1"])
        #expect(TranscriptGrouping.blockID(containing: "t2", in: before) == "work-t2")

        let older = [Self.user("u1"), Self.reply("a1", "Checking."), Self.tool("t1", "terminal")]
        let after = TranscriptGrouping.blocks(older + loaded, isRunning: false)
        #expect(Self.kinds(after) == ["u1", "work(c:a1 [t1,t2])", "a2", "u2", "b1"])
        #expect(TranscriptGrouping.blockID(containing: "t2", in: after) == "work-a1")
        #expect(TranscriptGrouping.blockID(containing: "u2", in: after) == "u2")
        #expect(TranscriptGrouping.blockID(containing: "gone", in: after) == nil)
    }

    // MARK: Steps

    @Test func stepsReadAsAKindAndALine() {
        var thinking = Self.reply("r1", "")
        thinking.reasoning = "\n**Checking the build**\nThe log says…"
        #expect(WorkStep.think(thinking).kind == "Think")
        #expect(WorkStep.think(thinking).summary == "Checking the build")
        #expect(WorkStep.think(thinking).copyText == thinking.reasoning)

        let bash = WorkStep.tool(Self.tool("t1", "terminal", args: ["command": "git status\ngit log -1", "workdir": "/repo/app"]))
        #expect(bash.kind == "Bash")
        #expect(bash.summary == "git status")
        #expect(bash.workdir == "/repo/app")
        #expect(bash.copyText == "git status\ngit log -1")

        let read = WorkStep.tool(Self.tool("t2", "read_file", args: .string(#"{"path":"x/y.md"}"#)))
        #expect(read.kind == "Read")
        #expect(read.summary == "x/y.md")
        #expect(read.workdir == nil)
        #expect(WorkStep.tool(Self.tool("t3", "browser_click")).kind == "Browser")
        #expect(WorkStep.tool(Self.tool("t4", "mystery", context: "the thing")).kind == "mystery")
    }

    @Test func groupsAreNamedAfterWhatTheirCallsDid() {
        let read = Self.tool("t1", "read_file", args: ["path": "a.swift"])
        let build = Self.tool("t2", "terminal", args: ["command": "swift build"], phase: .running)
        let other = Self.tool("t3", "mystery")
        let edit = Self.tool("t4", "patch")
        #expect(ToolCallSummary.groupTitle([build, read], live: false) == "Ran commands, read files")
        #expect(ToolCallSummary.groupTitle([read, build], live: true) == "Read files, running commands")
        #expect(ToolCallSummary.groupTitle([build, other, read, edit, build], live: false)
            == "Ran commands, called tools, read files, etc.")
        #expect(ToolCallSummary.groupTitle([], live: false) == "Analysis completed")
        #expect(ToolCallSummary.groupTitle([], live: true) == "Analyzing")
        let group = StepGroup(id: "g", steps: [.tool(read), .tool(Self.tool("t5", "terminal"))], isLive: false)
        #expect(group.title == "Read files, ran commands")
        #expect(group.iconTool == "read_file")
    }

    /// Text the model writes between steps splits them: one turn's work can hold several
    /// groups ("Analysis completed", the text, "Ran commands, …").
    @Test func textBetweenStepsSplitsTheWorkIntoGroups() throws {
        var thinking = Self.reply("r1", "")
        thinking.reasoning = "Plan the upgrade."
        let items = [
            Self.user("u1"), thinking,
            Self.reply("a1", "Understood — no backup.", interim: true),
            Self.tool("t1", "terminal"), Self.tool("t2", "mystery"), Self.tool("t3", "read_file"),
            Self.reply("a2", "Upgrade done."),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: false)
        #expect(Self.kinds(blocks) == ["u1", "work([~r1] c:a1 [t1,t2,t3])", "a2"])
        let groups = try #require(Self.work(blocks).first).entries.compactMap { entry -> String? in
            if case .group(let group) = entry { group.title } else { nil }
        }
        #expect(groups == ["Analysis completed", "Ran commands, called tools, read files"])
    }

}

@Suite struct ToolCallSummaryTests {
    static func tool(_ id: String, _ name: String, args: JSONValue? = nil, context: String? = nil,
                     phase: ToolActivity.Phase = .complete) -> TranscriptItem {
        TurnWorkTests.tool(id, name, args: args, context: context, phase: phase)
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
