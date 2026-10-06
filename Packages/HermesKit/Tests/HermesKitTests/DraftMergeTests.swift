import Testing

@testable import HermesKit

/// A failed prompt's text given back while an input method composes: the app's change
/// and the user's composition are both kept (`DraftMerge`).
@Suite struct DraftMergeTests {
    @Test func givenBackTextGoesAheadOfTheComposedCandidate() {
        // The draft mirrored the marked "ni"; the user then picked 你好.
        let result = DraftMerge.merge(base: "ni", theirs: "failed\nni", mine: "你好")
        #expect(result.text == "failed\n你好")
        #expect(result.caret == ("failed\n你好" as String).utf16.count)
    }

    @Test func givenBackTextIsKeptWhenTheMarkedTextWasNeverReported() {
        // The draft never saw the marked letters (no edit was reported for them).
        #expect(DraftMerge.merge(base: "", theirs: "failed", mine: "你").text == "failed你")
        #expect(DraftMerge.merge(base: "hi ", theirs: "failed\nhi ", mine: "hi 你").text == "failed\nhi 你")
    }

    @Test func aCancelledCompositionLeavesTheGivenBackText() {
        #expect(DraftMerge.merge(base: "hi ni", theirs: "failed\nhi ni", mine: "hi ").text == "failed\nhi ")
    }

    @Test func aChangeAfterTheCompositionIsKeptToo() {
        let result = DraftMerge.merge(base: "ni", theirs: "ni\nlater", mine: "你")
        #expect(result.text == "你\nlater")
        #expect(result.caret == 1)
    }

    @Test func compositionInTheMiddle() {
        #expect(DraftMerge.merge(base: "a ni b", theirs: "x\na ni b", mine: "a 你 b").text == "x\na 你 b")
        #expect(DraftMerge.merge(base: "a ni b", theirs: "a ni b!", mine: "a 你 b").text == "a 你 b!")
    }

    @Test func overlappingChangesKeepTheAppsDraft() {
        // Sent (cleared) while composing: the composed letters went with the send.
        #expect(DraftMerge.merge(base: "ni", theirs: "", mine: "你").text == "")
        #expect(DraftMerge.merge(base: "ni", theirs: "other chat", mine: "你").text == "other chat")
    }

    @Test func noChangeFromTheAppKeepsTheUsersText() {
        #expect(DraftMerge.merge(base: "ni", theirs: "ni", mine: "你").text == "你")
    }

    @Test func surrogatePairsSurvive() {
        #expect(DraftMerge.merge(base: "😀ni", theirs: "😃\n😀ni", mine: "😀你").text == "😃\n😀你")
    }
}
