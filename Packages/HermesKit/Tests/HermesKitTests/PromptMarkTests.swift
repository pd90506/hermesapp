import HermesKit
import Testing

/// The chat's prompt rail (`PromptMark`) and the send that scrolls the chat down
/// (`Transcript.lastPromptID`).
@Suite struct PromptMarkTests {
    @Test func eachPromptIsMarkedOldestFirst() {
        var transcript = Transcript()
        let first = transcript.appendUserPrompt("What is a monad?")
        let second = transcript.appendUserPrompt("And a functor?", displayKind: "steer")
        #expect(transcript.promptMarks == [
            PromptMark(id: first, label: "What is a monad?"),
            PromptMark(id: second, label: "And a functor?"),
        ])
    }

    @Test func repliesAndBackgroundNoticesAreNotMarked() {
        let items = [
            TranscriptItem(id: "u", role: .user, text: "Build it"),
            TranscriptItem(id: "a", role: .assistant, text: "Started."),
            TranscriptItem(id: "t", role: .tool, text: "make"),
            TranscriptItem(id: "n", role: .user, text: BackgroundNoticeTests.completion),
        ]
        #expect(PromptMark.marks(in: items).map(\.id) == ["u"])
    }

    @Test func theLabelIsTheFirstLineWithText() {
        let item = TranscriptItem(id: "u", role: .user, text: "\n   \n  Fix   the\tbuild  \nIt fails on CI.")
        #expect(PromptMark.label(for: item) == "Fix the build")
    }

    @Test func aLongPromptIsCut() {
        let item = TranscriptItem(id: "u", role: .user, text: String(repeating: "word ", count: 40))
        let label = PromptMark.label(for: item)
        #expect(label.count <= PromptMark.labelLimit)
        #expect(label.hasSuffix("word…"))
        #expect(PromptMark.label(for: TranscriptItem(id: "s", role: .user, text: "short"), limit: 5) == "short")
    }

    @Test func aPromptWithOnlyFilesIsLabelledWithThem() {
        var item = TranscriptItem(id: "u", role: .user, text: "")
        item.attachments = ["notes.md", "plan.pdf"]
        #expect(PromptMark.label(for: item) == "notes.md, plan.pdf")
        #expect(PromptMark.label(for: TranscriptItem(id: "i", role: .user, text: "")) == "Image")
    }

    @Test func aSendSetsTheLatestPrompt() {
        var transcript = Transcript()
        #expect(transcript.lastPromptID == nil)
        let first = transcript.appendUserPrompt("one")
        #expect(transcript.lastPromptID == first)
        let second = transcript.appendUserPrompt("two")
        #expect(transcript.lastPromptID == second)
        #expect(first != second)
    }

    @Test func theCurrentPromptIsTheLastOneAtOrAboveTheTopBlock() {
        var transcript = Transcript()
        let first = transcript.appendUserPrompt("one")
        let second = transcript.appendUserPrompt("two")
        let blocks = transcript.blocks
        let firstBlock = transcript.blockID(containing: first)
        let secondBlock = transcript.blockID(containing: second)
        #expect(transcript.currentPromptID(visibleBlockIDs: Set([firstBlock].compactMap { $0 })) == first)
        #expect(transcript.currentPromptID(visibleBlockIDs: Set([secondBlock].compactMap { $0 })) == second)
        #expect(transcript.currentPromptID(visibleBlockIDs: []) == nil)
        #expect(transcript.currentPromptID(visibleBlockIDs: ["gone"]) == nil)
        #expect(blocks.count >= 2)
    }

    @Test func aReplyBlockBelongsToThePromptAboveIt() {
        let items = [
            TranscriptItem(id: "u1", role: .user, text: "one"),
            TranscriptItem(id: "a1", role: .assistant, text: "reply one"),
            TranscriptItem(id: "u2", role: .user, text: "two"),
            TranscriptItem(id: "a2", role: .assistant, text: "reply two"),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: false)
        let marks = PromptMark.marks(in: items)
        let replyOne = TranscriptGrouping.blockID(containing: "a1", in: blocks)
        let replyTwo = TranscriptGrouping.blockID(containing: "a2", in: blocks)
        #expect(PromptMark.current(in: blocks, marks: marks, visible: Set([replyOne].compactMap { $0 })) == "u1")
        #expect(PromptMark.current(in: blocks, marks: marks, visible: Set([replyTwo].compactMap { $0 })) == "u2")
    }

    @Test func aBlockAboveEveryPromptIsAtTheFirst() {
        let items = [
            TranscriptItem(id: "s", role: .system, text: "Session resumed"),
            TranscriptItem(id: "u1", role: .user, text: "one"),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: false)
        let top = TranscriptGrouping.blockID(containing: "s", in: blocks)
        #expect(PromptMark.current(in: blocks, marks: PromptMark.marks(in: items), visible: Set([top].compactMap { $0 })) == "u1")
    }

    @Test func aChatAtItsEndIsAtItsLastPrompt() {
        let items = [
            TranscriptItem(id: "u1", role: .user, text: "one"),
            TranscriptItem(id: "a1", role: .assistant, text: "reply one"),
            TranscriptItem(id: "u2", role: .user, text: "two"),
            TranscriptItem(id: "a2", role: .assistant, text: "reply two"),
        ]
        let blocks = TranscriptGrouping.blocks(items, isRunning: false)
        let marks = PromptMark.marks(in: items)
        let ids = ["a1", "u2", "a2"].compactMap { TranscriptGrouping.blockID(containing: $0, in: blocks) }
        let onScreen = Set(ids)
        #expect(PromptMark.current(in: blocks, marks: marks, visible: onScreen) == "u2",
                "reply one fills the top of the screen, but the chat is scrolled to its end")
        let notAtEnd = onScreen.subtracting([ids.last!])
        #expect(PromptMark.current(in: blocks, marks: marks, visible: notAtEnd) == "u1")
    }
}
