import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Fixes after review 8 (round 9): a Stop after a redirect, and after a prompt that split
// the call's text, settles to one copy.

private func user(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "user", content: .string(text))
}

private func assistant(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "assistant", content: .string(text))
}

private func plain(_ range: ClosedRange<Int>) -> [StoredMessage] { range.map { storedRow(id: $0) } }

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func interrupted(_ text: String, rows: [Int]) -> JSONValue {
    var payload = completePayload(text, rows: rows).objectValue ?? [:]
    payload["status"] = "interrupted"
    return .object(payload)
}

@Suite struct StopAfterRedirectTests {
    private func idle() throws -> Transcript {
        var transcript = Transcript(snapshot: try deferredAck(sid: "sid-1", key: "s1", count: 300)
            .decode(LiveSessionSnapshot.self))
        transcript.installLatestPage(plain(181...300), hasOlder: true)
        return transcript
    }

    /// Two quiet re-reads of `rows`, as a redirected or queued prompt needs.
    private func settle(_ transcript: inout Transcript, _ rows: [StoredMessage]) {
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
    }

    private func expectAllStored(_ transcript: Transcript, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(transcript.historyCount == transcript.items.count,
                "live items left: \(transcript.items[transcript.historyCount...].map(\.text))",
                sourceLocation: sourceLocation)
        expectWellFormed(transcript, sourceLocation: sourceLocation)
    }

    /// The default `busy_input_mode: interrupt` turns a prompt sent during a reply into a
    /// redirect (`session_auto_continue.py:404-430`), which sends no event: the text after
    /// it runs on in the same segment after a `"\n\n"` (`conversation_loop.py:364-365`).
    /// The pre-redirect text is stored as a placeholder (`conversation_loop.py:345-353`);
    /// Stop stores and sends the post-redirect partial (`agent/turn_api_call.py:194-213`).
    @Test func aStopAfterARedirectShowsThePartialOnce() throws {
        var transcript = try idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "先看配置"]))
        let prompt = transcript.appendUserPrompt("改成看日志")
        transcript.promptAnswered(itemID: prompt, status: "redirected")
        transcript.apply(event("message.delta", ["text": "文件"]))
        transcript.apply(event("message.delta", ["text": "\n\n日志在这"]))
        transcript.apply(event("message.complete", interrupted("日志在这", rows: [301, 302, 303, 304])))
        let rows = plain(185...300) + [user(301, "看看配置"), assistant(302, "先看配置文件"),
                                       user(303, "改成看日志"), assistant(304, "日志在这")]
        settle(&transcript, rows)
        #expect(occurrences(transcript, "日志在这") == 1)
        #expect(occurrences(transcript, "先看配置") == 1)
        #expect(occurrences(transcript, "改成看日志") == 1)
        expectAllStored(transcript)
    }

    /// The same redirect sent by another client: no bubble here, one segment.
    @Test func aStopAfterAForeignRedirectShowsThePartialOnce() throws {
        var transcript = try idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "先看配置"]))
        transcript.apply(event("message.delta", ["text": "文件"]))
        transcript.apply(event("message.delta", ["text": "\n\n日志在这"]))
        transcript.apply(event("message.complete", interrupted("日志在这", rows: [301, 302, 303, 304])))
        let rows = plain(185...300) + [user(301, "看看配置"), assistant(302, "先看配置文件"),
                                       user(303, "改成看日志"), assistant(304, "日志在这")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        #expect(occurrences(transcript, "日志在这") == 1)
        #expect(occurrences(transcript, "先看配置") == 1)
        expectAllStored(transcript)
    }

    /// A prompt queued here mid-reply leaves the call's text in one segment above it (the
    /// call goes on, `promptAnswered`); Stop stores and sends the whole call's partial.
    @Test func aStopAfterAQueuedSplitShowsThePartialOnce() throws {
        var transcript = try idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "第一部分，"]))
        let prompt = transcript.appendUserPrompt("顺便看下日志")
        transcript.promptAnswered(itemID: prompt, status: "queued")
        transcript.apply(event("message.delta", ["text": "第二部分"]))
        #expect(transcript.items.filter { $0.role == .assistant && $0.rowID == nil }.map(\.text) == ["第一部分，第二部分"])
        transcript.apply(event("message.complete", interrupted("第一部分，第二部分", rows: [301, 302])))
        let rows = plain(184...300) + [user(301, "开始"), assistant(302, "第一部分，第二部分"),
                                       user(303, "顺便看下日志")]
        settle(&transcript, rows)
        #expect(occurrences(transcript, "第一部分") == 1)
        #expect(occurrences(transcript, "第二部分") == 1)
        #expect(occurrences(transcript, "顺便看下日志") == 1)
        expectAllStored(transcript)
    }
}
