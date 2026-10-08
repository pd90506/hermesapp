import HermesKit
import SwiftUI

/// An assistant reply: reasoning disclosure, the rendered Markdown, and the
/// action bar. Menus belong to the row that hosts it.
///
/// A reply with nothing to show yet is not drawn at all (`isBlank`): the waiting
/// row stands in for it (`ResponseWaitingRow`). The action bar comes once there is
/// text to copy.
struct AssistantMessageContent: View {
    let item: TranscriptItem
    var isHovering = false
    var isNewest = false
    var conversationSource: (() -> String)?
    let copy: () -> Void

    /// No text (whitespace counts as none, as for the waiting row and the action bar),
    /// no reasoning and no outcome to show: the row has no content yet.
    static func isBlank(_ item: TranscriptItem) -> Bool {
        !hasText(item) && item.reasoning.isEmpty && item.outcome != "interrupted"
    }

    private static func hasText(_ item: TranscriptItem) -> Bool {
        !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !item.reasoning.isEmpty {
                    // Model-written like the reply, so rendered the same way; the
                    // content is only built while expanded.
                    DisclosureGroup("Reasoning") {
                        MarkdownView(text: item.reasoning, isStreaming: item.isActive, isReasoning: true)
                            .equatable()
                    }
                    .font(.caption)
                }
                if Self.hasText(item) {
                    MarkdownView(text: item.text, isStreaming: item.isActive, conversationSource: conversationSource)
                        .equatable()
                }
                if item.outcome == "interrupted" {
                    Text("Interrupted").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Directly under the message, so moving down onto it never leaves the row.
            if ConversationMarkdown.hasActionBar(item) {
                MessageActionBar(isHovering: isHovering, isNewest: isNewest, copy: copy)
            }
        }
    }
}

/// A tool call card: name and up to three lines of detail. No action bar
/// (Copy Message is in its context menu), so a run of tool calls stays compact.
struct ToolMessageContent: View {
    let item: TranscriptItem

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.toolName ?? "tool").font(.callout.monospaced())
                    if let detail = item.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            } icon: {
                if item.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                }
            }
            Spacer(minLength: 4)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// The transcript's rows as the chat shows them, in order:
/// - each message, drawn by `message` (a reply with nothing to show yet is skipped:
///   the waiting row stands in for it);
/// - the waiting row, in the reply's place, while one is awaited (`Transcript.waiting`);
/// - the request cards (`requests`);
/// - the turn's status line, except while waiting (it is the waiting row's hint);
/// - the last error.
///
/// Its body is several views, laid out by the enclosing stack like a `Group`'s.
struct TranscriptMessages<Message: View, Requests: View>: View {
    let transcript: Transcript
    @ViewBuilder let message: (_ item: TranscriptItem, _ isNewest: Bool) -> Message
    @ViewBuilder let requests: () -> Requests

    var body: some View {
        let newestID = ConversationMarkdown.newestMessageID(in: transcript.items)
        ForEach(transcript.items) { item in
            if !(item.role == .assistant && AssistantMessageContent.isBlank(item)) {
                message(item, item.id == newestID)
            }
        }
        let waiting = transcript.waiting
        if let waiting {
            ResponseWaitingRow(waiting: waiting)
        }
        requests()
        if waiting == nil, let status = transcript.status, transcript.isRunning {
            Label(status, systemImage: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let lastError = transcript.lastError {
            Label(lastError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

/// Stands in for the reply from the send until it shows text or a tool row
/// (`Transcript.waiting`), as Desktop's `ResponseLoadingIndicator` does
/// (`components/assistant-ui/thread/status.tsx:243-268`): a pulsing mark, the
/// label ("Thinking…", or what Hermes says the wait is about) and the time since
/// the send. One line in the reply's font, where the reply's first line will be,
/// so the reply takes its place without a jump.
struct ResponseWaitingRow: View {
    let waiting: Transcript.Waiting
    /// For a turn this chat did not send: count from when the row appeared.
    @State private var appeared = Date()

    static let accessibilityLabel = "Hermes is responding"

    var body: some View {
        HStack(spacing: 8) {
            WaitingPulse()
            Text(waiting.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Transcript.Waiting.elapsedText(from: waiting.since ?? appeared, to: context.date))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityValue(waiting.hint ?? "")
    }
}

/// A small square that breathes; still under Reduce Motion.
private struct WaitingPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            mark(opacity: 0.7)
        } else {
            PhaseAnimator([1.0, 0.3]) { opacity in
                mark(opacity: opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        }
    }

    private func mark(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.secondary)
            .frame(width: 8, height: 8)
            .opacity(opacity)
    }
}
