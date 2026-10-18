import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

/// A reply streaming at the end of a long chat. The chat reads its transcript whole, so
/// each change to it updates the chat: shown a delta at a time, a long reply kept the
/// main thread busy for the whole stream, and scrolling stuttered. Now the deltas show a
/// batch at a time (`StreamedTextQueue`).
@MainActor
@Suite(.serialized) struct StreamingTests {
    @MainActor @Observable final class Chat {
        var transcript: Transcript

        init(transcript: Transcript) { self.transcript = transcript }
    }

    enum Mode: CaseIterable {
        /// As before: each delta shown on its own.
        case eachDelta
        /// As now: the deltas a batch at a time (`StreamedTextQueue`).
        case batches
    }

    /// `ChatView`'s scroll view, with its rows drawn as `MessageRow` draws them.
    private struct Harness: View {
        let chat: Chat

        var body: some View {
            ScrollView {
                TranscriptStack {
                    TranscriptMessages(transcript: chat.transcript) { item, isNewest in
                        Row(item: item, isNewest: isNewest, chat: chat)
                    } requests: {
                        EmptyView()
                    }
                }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private struct Row: View {
        let item: TranscriptItem
        let isNewest: Bool
        let chat: Chat

        var body: some View {
            switch item.role {
            case .user:
                Text(item.text).padding(10).frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                MessageHoverArea { isHovering in
                    AssistantMessageContent(item: item, isHovering: isHovering, isNewest: isNewest,
                                            conversationSource: { ConversationMarkdown.export(chat.transcript.items) },
                                            copy: {})
                }
            case .tool:
                ToolMessageContent(item: item)
            case .system:
                Text(item.text)
            }
        }
    }

    static func event(_ type: String, _ payload: [String: JSONValue] = [:]) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: .object(payload))
    }

    /// A long reply as a model streams it: paragraphs, a list, code and a table, in
    /// deltas of a few words.
    static func streamedReply() -> [String] {
        let text = (0..<6).map { ChatSwitchTests.reply($0) }.joined(separator: "\n\n")
        var deltas: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let chunk = rest.prefix(24)
            deltas.append(String(chunk))
            rest = rest.dropFirst(chunk.count)
        }
        return deltas
    }

    @MainActor private final class UI {
        static let size = CGSize(width: 900, height: 800)
        let chat: Chat
        let window: NSWindow
        let host: NSView

        init(pages: Int) {
            var transcript = Transcript()
            let rows = (0..<pages).reversed().flatMap { ChatSwitchTests.page(seed: $0) }
            transcript.installLatestPage(rows, hasOlder: false)
            chat = Chat(transcript: transcript)
            window = NSWindow(contentRect: .testArea(Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: Harness(chat: chat))
            window.contentView = host
            window.showInTestArea()
        }

        func close() { window.close() }

        /// Gives the main thread to the app for a moment, returning how long the app
        /// kept it beyond the pause asked for.
        func turn() async -> TimeInterval {
            let start = Date()
            try? await Task.sleep(for: .milliseconds(4))
            return max(0, Date().timeIntervalSince(start) - 0.004)
        }

        /// Lets the chat settle: turns until a quiet stretch, or 5 s at most (a VM's
        /// timers can run late on every turn).
        func settle() async {
            let start = Date()
            var quiet = 0
            while quiet < 20, Date().timeIntervalSince(start) < 5 {
                quiet = await turn() < 0.008 ? quiet + 1 : 0
            }
        }
    }

    /// The main thread's work, from its run loop: each pass from waking to waiting
    /// again. Timers in a VM run late on every turn, so the time a sleep takes is no
    /// measure of how busy the thread was.
    final class MainThreadLoad {
        private var observer: CFRunLoopObserver?
        private var woke: CFAbsoluteTime?
        private(set) var passes: [CFTimeInterval] = []
        private let start = CFAbsoluteTimeGetCurrent()

        init() {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting {
                    woke = now
                } else if let woke {
                    passes.append(now - woke)
                    self.woke = nil
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// Stops counting; returns the share of the time the thread worked, its longest
        /// pass, and how many passes took longer than a frame at 60 Hz.
        func stop() -> String {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let busy = passes.reduce(0, +) / elapsed
            return String(format: "busy %.0f%%, longest pass %.0f ms, %d passes over 16 ms, %.1f s",
                          busy * 100, (passes.max() ?? 0) * 1000, passes.filter { $0 > 1.0 / 60 }.count, elapsed)
        }

        var busy: Double { passes.reduce(0, +) / (CFAbsoluteTimeGetCurrent() - start) }
    }

    /// The main thread while a long reply streams, a delta every 16 ms (60 a second), at
    /// the end of a chat of two pages of stored rows, as before and now; then as now in a
    /// chat of the reply alone, for what the stored rows add. Prints the numbers, so the
    /// VM log carries them.
    @Test(.timeLimit(.minutes(5))) func aStreamingReplyLeavesTheMainThreadMostlyFree() async throws {
        let deltas = Self.streamedReply()
        var busy: [Mode: Double] = [:]
        var report = "streaming \(deltas.count) deltas, one every 16 ms, after \(2 * ChatSession.pageSize) stored rows:"
        for (mode, pages) in [(Mode.eachDelta, 2), (.batches, 2), (.batches, 0)] {
            let ui = UI(pages: pages)
            defer { ui.close() }
            await ui.settle()
            _ = ui.chat.transcript.appendUserPrompt("Write a long answer")
            ui.chat.transcript.apply(Self.event("message.start"))
            await ui.settle()
            let chat = ui.chat
            let queue = StreamedTextQueue { events in
                for event in events { chat.transcript.apply(event) }
            }
            let clock = ContinuousClock()
            var next = clock.now
            let load = MainThreadLoad()
            for delta in deltas {
                let event = Self.event("message.delta", ["text": .string(delta)])
                if mode == .batches { queue.append(event) } else { chat.transcript.apply(event) }
                next += .milliseconds(16)
                try? await Task.sleep(until: next, clock: clock)
            }
            while !queue.isEmpty { _ = await ui.turn() }
            _ = await ui.turn()
            if pages > 0 { busy[mode] = load.busy }
            report += "\n  \(mode)\(pages > 0 ? "" : ", no stored rows"): \(load.stop())"
            #expect(chat.transcript.items.last?.text == deltas.joined())
        }
        print(report)
        let before = try #require(busy[.eachDelta]), now = try #require(busy[.batches])
        #expect(now < before / 2, "\(report)")
    }
}
