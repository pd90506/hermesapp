@testable import HermesKit
import Testing

/// The count on the chat's scroll-to-bottom button (`MessagesBelow`): the messages under
/// the last block on screen, a turn's work and its answer as one reply, as Desktop's.
@Suite struct MessagesBelowTests {
    typealias T = TurnWorkTests

    static var items: [TranscriptItem] {
        [
            T.user("u1"), T.reply("a1", "First answer."),
            T.user("u2"), T.tool("t2", "terminal"), T.reply("a2", "Ran it."),
            T.user("u3"), T.reply("a3", "Third answer."),
        ]
    }

    static var blocks: [TranscriptBlock] { TranscriptGrouping.blocks(items, isRunning: false) }

    @Test func countsThePromptsAndRepliesBelowTheLastBlockOnScreen() {
        // u1 a1 | u2 work(t2) a2 u3 a3: two prompts and two replies below.
        #expect(MessagesBelow.count(in: Self.blocks, visible: ["u1", "a1"]) == 4)
        // Only the first block on screen: its reply too.
        #expect(MessagesBelow.count(in: Self.blocks, visible: ["u1"]) == 5)
    }

    @Test func nothingBelowTheLastBlock() {
        #expect(MessagesBelow.count(in: Self.blocks, visible: ["a3"]) == 0)
        #expect(MessagesBelow.count(in: Self.blocks, visible: ["u3", "a3"]) == 0)
    }

    @Test func noBlockOnScreenCountsNothing() {
        #expect(MessagesBelow.count(in: Self.blocks, visible: []) == 0)
        #expect(MessagesBelow.count(in: Self.blocks, visible: ["gone"]) == 0)
    }

    @Test func workWithNoAnswerYetIsAReplyOfItsOwn() {
        let items = [T.user("u1"), T.reply("a1", "Hi."), T.user("u2"), T.tool("t2", "terminal", phase: .running),
                     TranscriptItem(id: "a2", role: .assistant, text: "", isActive: true)]
        let blocks = TranscriptGrouping.blocks(items, isRunning: true)
        // u2 and its running work; the blank reply waiting under it is no message yet.
        #expect(MessagesBelow.count(in: blocks, visible: ["a1"]) == 2)
    }

    @Test func theTranscriptCountsItsOwnBlocks() {
        var transcript = Transcript()
        let first = transcript.appendUserPrompt("one")
        transcript.appendUserPrompt("two")
        #expect(transcript.messagesBelow(visibleBlockIDs: [first]) == 1)
    }

    @Test func theButtonSaysHowManyAsDesktop() {
        #expect(MessagesBelow.title(count: 0) == "Scroll to bottom")
        #expect(MessagesBelow.title(count: 1) == "1 message")
        #expect(MessagesBelow.title(count: 4) == "4 messages")
        #expect(MessagesBelow.accessibilityLabel(count: 0) == "Scroll to bottom")
        #expect(MessagesBelow.accessibilityLabel(count: 4) == "Scroll to bottom · 4 messages")
    }
}
