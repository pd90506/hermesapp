import HermesKit
import Testing

@Suite struct BackgroundNoticeTests {
    /// As `format_process_notification` writes a completion
    /// (`tools/process_registry_notifications.py:469-471`).
    static let completion = """
    [IMPORTANT: Background process proc_3f2a completed normally (exit code 0).
    Command: python3 build.py
    Output:
    done in 4s]
    """

    @Test func aProcessCompletionIsANotice() throws {
        let notice = try #require(BackgroundNotice(Self.completion))
        #expect(notice.headline == "Background process proc_3f2a completed normally (exit code 0).")
        #expect(notice.detail == "Command: python3 build.py\nOutput:\ndone in 4s")
    }

    @Test func heartbeatsAndSubagentResultsAreNotices() throws {
        let heartbeat = try #require(BackgroundNotice(
            "[Background process proc_1 heartbeat #2 — still running after 1m (next in 60s).\nCommand: sleep 100\nOutput since last heartbeat:\n]"))
        #expect(heartbeat.headline.hasPrefix("Background process proc_1 heartbeat #2"))
        let subagent = try #require(BackgroundNotice("[ASYNC DELEGATION COMPLETE — d_9]\nA background subagent you dispatched earlier has finished."))
        #expect(subagent.headline == "[ASYNC DELEGATION COMPLETE — d_9]")
        #expect(BackgroundNotice("A background subagent you dispatched earlier has finished. Result: ok") != nil)
    }

    @Test func whatTheUserTypesIsNot() {
        #expect(BackgroundNotice("Please run the background process again") == nil)
        #expect(BackgroundNotice("[IMPORTANT: read this]") == nil)
        let assistant = TranscriptItem(id: "a", role: .assistant, text: Self.completion)
        #expect(assistant.backgroundNotice == nil)
    }

    @Test func aNoticeDoesNotTakeTheNewestBar() {
        let reply = TranscriptItem(id: "reply", role: .assistant, text: "Started it.")
        let notice = TranscriptItem(id: "notice", role: .user, text: Self.completion)
        #expect(ConversationMarkdown.newestMessageID(in: [reply, notice]) == "reply")
    }
}
