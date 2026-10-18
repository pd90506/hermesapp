import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

/// Switching chats. Built afresh for the chat clicked, the chat's scroll view
/// (`ChatView`) set and laid out every row's Markdown of a full page of stored rows
/// before the first frame: about a second with nothing on screen moving. Now a chat
/// shown before is kept built while hidden (`keptChat`), and one built afresh shows its
/// newest rows first (`TranscriptWindow`) and the rows above them in the frames after.
@MainActor
@Suite(.serialized) struct ChatSwitchTests {
    @MainActor @Observable final class Chats {
        var transcripts: [Transcript] = []
        var shown = 0
    }

    enum Mode: CaseIterable {
        /// Every row built at once, as before.
        case allAtOnce
        /// Built afresh, newest rows first: a chat's first open.
        case newestFirst
        /// Kept built while hidden: going back to a chat.
        case kept
    }

    /// `ChatView`'s scroll view, with its rows drawn as `MessageRow` draws them, in
    /// `RootView`'s place: one chat at a time, or kept chats as `KeptChats` keeps them.
    private struct Harness: View {
        let chats: Chats
        let mode: Mode
        @State private var built: Set<Int> = []

        var body: some View {
            switch mode {
            case .allAtOnce, .newestFirst:
                ChatPane(transcript: chats.transcripts[chats.shown], windowed: mode == .newestFirst)
                    .id(chats.shown)
            case .kept:
                ZStack {
                    ForEach(chats.transcripts.indices.filter { built.contains($0) || $0 == chats.shown }, id: \.self) { index in
                        ChatPane(transcript: chats.transcripts[index], windowed: true)
                            .keptChat(isShown: index == chats.shown)
                    }
                }
                .onChange(of: chats.shown, initial: true) { _, index in built.insert(index) }
            }
        }
    }

    private struct ChatPane: View {
        let transcript: Transcript
        let windowed: Bool
        @State private var window = TranscriptWindow()

        var body: some View {
            ScrollView {
                TranscriptStack {
                    TranscriptMessages(transcript: transcript) { item, _ in
                        switch item.role {
                        case .user:
                            Text(item.text).padding(10).frame(maxWidth: .infinity, alignment: .trailing)
                        case .assistant:
                            AssistantMessageContent(item: item) {}
                        case .tool:
                            ToolMessageContent(item: item)
                        case .system:
                            Text(item.text)
                        }
                    } requests: {
                        EmptyView()
                    }
                }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .transcriptWindow(windowed ? window : nil, isEmpty: transcript.items.isEmpty) { transcript.blocks }
        }
    }

    /// A page of stored rows as an agent chat has them: prompts, tool calls with their
    /// results, and replies of paragraphs, lists, code and tables.
    static func page(seed: Int, rows count: Int = ChatSession.pageSize) -> [StoredMessage] {
        var rows: [StoredMessage] = []
        var id = seed * 10_000
        func next() -> Int { id += 1; return id }
        var turn = 0
        while rows.count < count {
            rows.append(StoredMessage(id: next(), role: "user",
                                      content: .string("Prompt \(turn) of chat \(seed): look into the build and fix it")))
            for call in 0..<(turn % 3) {
                let callID = "c\(seed)-\(turn)-\(call)"
                var ask = StoredMessage(id: next(), role: "assistant", content: .string(""))
                ask.toolCalls = [["id": .string(callID), "type": "function",
                                  "function": ["name": "terminal", "arguments": #"{"command":"make test"}"#]]]
                var result = StoredMessage(id: next(), role: "tool",
                                           content: .string((1...20).map { "test \($0) passed" }.joined(separator: "\n")))
                result.toolCallID = callID
                result.toolName = "terminal"
                rows += [ask, result]
            }
            rows.append(StoredMessage(id: next(), role: "assistant", content: .string(reply(turn))))
            turn += 1
        }
        return Array(rows.suffix(count))
    }

    static func reply(_ turn: Int) -> String {
        let paragraph = "A paragraph of the reply that runs long enough to wrap over several lines, "
            + "with **bold**, `inline code`, *emphasis* and a [link](https://example.com) in it."
        var parts = (0...(turn % 4)).map { _ in paragraph }
        parts.append((1...4).map { "- item \($0) with `code` and **weight**" }.joined(separator: "\n"))
        if turn % 2 == 0 {
            parts.append("```swift\n" + (1...12).map { "let value\($0) = compute(\($0)) // step \($0)" }
                .joined(separator: "\n") + "\n```")
        }
        if turn % 3 == 0 {
            parts.append("| Command | Output |\n|---|---|\n"
                + (1...5).map { "| `echo \($0)` | a longer cell that wraps \($0) |" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func transcript(seed: Int) -> Transcript {
        var transcript = Transcript()
        transcript.installLatestPage(page(seed: seed), hasOlder: true)
        return transcript
    }

    @MainActor private final class UI {
        static let size = CGSize(width: 900, height: 800)
        let chats = Chats()
        let window: NSWindow
        let host: NSView

        init(mode: Mode) {
            chats.transcripts = (0..<3).map { ChatSwitchTests.transcript(seed: $0) }
            window = NSWindow(contentRect: .testArea(Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: Harness(chats: chats, mode: mode))
            window.contentView = host
            window.showInTestArea()
        }

        func close() { window.close() }

        /// Gives the main thread to the app for a moment, returning how long it took to
        /// come back: a long wait is the main thread busy, the app frozen. (Spinning the
        /// run loop from a synchronous test never resumed the chat's own tasks.)
        func turn() async -> TimeInterval {
            let start = Date()
            try? await Task.sleep(for: .milliseconds(4))
            return Date().timeIntervalSince(start)
        }

        var scrollView: NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        var contentHeight: CGFloat { scrollView?.documentView?.frame.height ?? 0 }

        /// How much content is below the visible part.
        var remainingBelow: CGFloat? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let bounds = scroll.contentView.bounds
            return document.isFlipped ? document.frame.height - bounds.maxY : bounds.minY
        }

        struct Switch {
            /// From the click to the end of the first run-loop turn: the new chat's
            /// first frame, and how long nothing else could happen.
            var firstFrame: TimeInterval
            /// The longest turn of the run loop until the chat was fully built.
            var longestStall: TimeInterval
            /// From the click until every row of the page was built.
            var complete: TimeInterval
            /// The content's height once built.
            var height: CGFloat
        }

        /// Switches to chat `index` and times it, until the content stops growing.
        func switchTo(_ index: Int) async -> Switch {
            let start = Date()
            chats.shown = index
            var turns: [TimeInterval] = []
            var firstFrame: TimeInterval?
            var lastGrowth = start
            var height = contentHeight
            while Date().timeIntervalSince(lastGrowth) < 0.5 {
                turns.append(await turn())
                let now = Date()
                if firstFrame == nil { firstFrame = now.timeIntervalSince(start) }
                if contentHeight != height {
                    height = contentHeight
                    lastGrowth = now
                }
            }
            return Switch(firstFrame: firstFrame ?? 0, longestStall: turns.max() ?? 0,
                          complete: lastGrowth.timeIntervalSince(start), height: height)
        }
    }

    private func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f ms", seconds * 1000) }

    /// Switching between chats of a full page each: every row built at once (as
    /// before), built afresh newest rows first (a first open), and kept built (going
    /// back). Prints the three, so the VM log carries the numbers.
    @Test func switchingIsQuick() async throws {
        var results: [Mode: [UI.Switch]] = [:]
        for mode in Mode.allCases {
            let ui = UI(mode: mode)
            defer { ui.close() }
            // The first visits warm caches (parsed Markdown, typeset math) for every
            // chat, as chats seen before in the app are, and build the kept chats.
            for index in [0, 1, 2, 0] { _ = await ui.switchTo(index) }
            var switches: [UI.Switch] = []
            for index in [1, 2, 0, 1, 2, 0] { switches.append(await ui.switchTo(index)) }
            results[mode] = switches
            let below = try #require(ui.remainingBelow)
            #expect(below < 2, "\(mode): the switched-to chat sits at its newest row (\(below) pt below)")
        }
        func median(_ values: [TimeInterval]) -> TimeInterval { values.sorted()[values.count / 2] }
        let before = try #require(results[.allAtOnce])
        var report = "chat switch, \(ChatSession.pageSize) rows a chat (median of \(before.count)):"
        for mode in Mode.allCases {
            let runs = results[mode] ?? []
            report += "\n  \(mode): first frame \(ms(median(runs.map(\.firstFrame)))), "
                + "longest stall \(ms(median(runs.map(\.longestStall)))), complete \(ms(median(runs.map(\.complete))))"
        }
        print(report)
        let fresh = try #require(results[.newestFirst]), kept = try #require(results[.kept])
        for (all, other) in zip(before, fresh + kept) {
            #expect(abs(all.height - other.height) < 1, "the whole page is built: \(other.height) of \(all.height) pt")
        }
        let stall = median(before.map(\.longestStall))
        #expect(median(fresh.map(\.longestStall)) < stall / 3, "\(report)")
        #expect(median(kept.map(\.longestStall)) < stall / 10, "\(report)")
    }
}
