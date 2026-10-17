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
}
