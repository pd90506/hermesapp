import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

/// Issue #5 in the real row views: a reply with nothing to show is not drawn (no
/// bare "…", no action bar), and the waiting row stands in for it.
@MainActor
@Suite struct WaitingRowHostTests {
    private func height(_ view: some View, width: CGFloat = 400) -> CGFloat {
        NSHostingView(rootView: view.frame(width: width)).fittingSize.height
    }

    /// Drawn on white in light mode; the darkest pixel tells whether anything shows.
    private func darkest(_ view: some View, width: CGFloat = 400) throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: max(host.fittingSize.height, 1))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var darkest: CGFloat = 1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                darkest = min(darkest, rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1)
            }
        }
        return darkest
    }

    private func reply(text: String = "", reasoning: String = "", active: Bool = true,
                       outcome: String? = nil) -> TranscriptItem {
        var item = TranscriptItem(id: "a", role: .assistant, text: text)
        item.reasoning = reasoning
        item.isActive = active
        item.outcome = outcome
        return item
    }

    @Test func aBlankReplyDrawsNothingEvenAsTheNewest() throws {
        let blank = reply()
        #expect(AssistantMessageContent.isBlank(blank))
        let row = AssistantMessageContent(item: blank, isHovering: true, isNewest: true) {}
        // Zero height: neither a bare "…" nor an action bar is drawn.
        #expect(height(row) == 0, "a bare \"…\" or an action bar is drawn for a reply with no content")
    }

    @Test func reasoningAloneHasNoActionBar() {
        let thinking = reply(reasoning: "Let me think.")
        #expect(!AssistantMessageContent.isBlank(thinking))
        let disclosure = height(ReasoningFold(item: thinking))
        let row = height(AssistantMessageContent(item: thinking, isHovering: true, isNewest: true) {})
        #expect(abs(row - disclosure) <= 1, "row \(row) vs disclosure \(disclosure): an action bar under nothing to copy")
    }

    @Test func anInterruptedReplyWithNoTextShowsOnlyTheLabel() {
        let stopped = reply(active: false, outcome: "interrupted")
        #expect(!AssistantMessageContent.isBlank(stopped))
        let label = height(Text("Interrupted").font(.caption))
        let row = height(AssistantMessageContent(item: stopped, isHovering: true, isNewest: true) {})
        #expect(abs(row - label) <= 1, "row \(row) vs label \(label)")
    }

    @Test func textBringsTheBar() {
        let answered = reply(text: "Hi.")
        let text = height(MarkdownView(text: "Hi.", isStreaming: true))
        let bar = height(MessageActionBar(isHovering: false, isNewest: true) {})
        let row = height(AssistantMessageContent(item: answered, isNewest: true) {})
        #expect(abs(row - (text + bar)) <= 1)
    }

    // MARK: The rows `ChatView` draws (`TranscriptMessages`), from the real reducer

    @MainActor private final class Drawn { var ids: Set<String> = [] }

    private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
    }

    /// A chat after "hello" was sent and its turn started, nothing shown yet.
    private func waitingTranscript() -> Transcript {
        var transcript = Transcript()
        transcript.installLatestPage([], hasOlder: false)
        transcript.appendUserPrompt("hello", sentAt: Date().addingTimeInterval(-4))
        transcript.apply(event("message.start"))
        return transcript
    }

    /// `TranscriptMessages` as `ChatView` uses it; records which items it drew.
    private func rows(_ transcript: Transcript, _ drawn: Drawn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TranscriptMessages(transcript: transcript) { item, isNewest in
                let _ = drawn.ids.insert(item.id)
                if item.role == .assistant {
                    AssistantMessageContent(item: item, isNewest: isNewest) {}
                } else {
                    Text(item.text)
                }
            } requests: {
                EmptyView()
            }
        }
    }

    /// The prompt, then the waiting row: what the rows must look like while waiting.
    private func promptAndWaiting(_ waiting: Transcript.Waiting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("hello")
            ResponseWaitingRow(waiting: waiting)
        }
    }

    @Test func theWaitingRowStandsInForTheEmptyReply() throws {
        let transcript = waitingTranscript()
        let waiting = try #require(transcript.waiting)
        let drawn = Drawn()
        let drawnHeight = height(rows(transcript, drawn))
        let reply = try #require(transcript.items.last { $0.role == .assistant })
        #expect(!drawn.ids.contains(reply.id), "the empty reply is drawn")
        #expect(drawn.ids.count == 1, "only the prompt")
        #expect(abs(drawnHeight - height(promptAndWaiting(waiting))) <= 1, "the waiting row follows the prompt, nothing else")
        #expect(waiting.label == "Thinking…")
        #expect(ResponseWaitingRow.accessibilityLabel == "Hermes is responding")
    }

    /// S3: a first delta of only whitespace draws no reply row above the waiting row.
    @Test func aWhitespaceReplyDrawsNoRow() throws {
        var transcript = waitingTranscript()
        transcript.apply(event("message.delta", ["text": "\n"]))
        let waiting = try #require(transcript.waiting)
        let drawn = Drawn()
        let drawnHeight = height(rows(transcript, drawn))
        #expect(drawn.ids.count == 1, "a whitespace-only reply is drawn")
        #expect(abs(drawnHeight - height(promptAndWaiting(waiting))) <= 1)
    }

    /// While waiting the status is the waiting row's hint, not a second line; once
    /// the reply shows, the status line is back below it.
    @Test func theStatusIsTheHintWhileWaiting() throws {
        var transcript = waitingTranscript()
        transcript.apply(event("status.update", ["kind": "compacting", "text": "Summarizing thread"]))
        let waiting = try #require(transcript.waiting)
        #expect(waiting.label == "Summarizing thread")
        #expect(abs(height(rows(transcript, Drawn())) - height(promptAndWaiting(waiting))) <= 1,
                "the status shows twice")

        transcript.apply(event("message.delta", ["text": "Hi."]))
        #expect(transcript.waiting == nil)
        let drawn = Drawn()
        let after = height(rows(transcript, drawn))
        let reply = try #require(transcript.items.last { $0.role == .assistant })
        #expect(drawn.ids.contains(reply.id))
        let expected = height(VStack(alignment: .leading, spacing: 12) {
            Text("hello")
            AssistantMessageContent(item: reply, isNewest: true) {}
            Label("Summarizing thread", systemImage: "ellipsis").font(.caption)
        })
        #expect(abs(after - expected) <= 1)
    }

    /// S1 through the reducer: Stop before any text leaves "Interrupted", with no bar.
    @Test func stopBeforeAnyTextShowsInterrupted() throws {
        var transcript = waitingTranscript()
        transcript.apply(event("message.complete", ["text": "", "status": "interrupted"]))
        #expect(transcript.waiting == nil)
        let mark = try #require(transcript.items.last { $0.outcome == "interrupted" })
        let drawn = Drawn()
        _ = height(rows(transcript, drawn))
        #expect(drawn.ids.contains(mark.id), "the mark is skipped as blank")
        let label = height(Text("Interrupted").font(.caption))
        let row = height(AssistantMessageContent(item: mark, isHovering: true, isNewest: true) {})
        #expect(abs(row - label) <= 1, "row \(row) vs label \(label): an action bar under nothing to copy")
    }
}
