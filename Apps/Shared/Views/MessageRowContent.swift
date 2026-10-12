import HermesKit
import HermesProtocol
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
    static func isBlank(_ item: TranscriptItem) -> Bool { item.isBlankReply }

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

/// One tool call, as Desktop draws it: a single line (status, what it did, chevron)
/// that opens on demand to the call's input, output, diff or error. A file edit
/// with a diff opens by default, with its +/− counts on the line. No action bar
/// (Copy Message is in its context menu), so a run of tool calls stays compact.
struct ToolMessageContent: View {
    let item: TranscriptItem
    /// The user's choice; until then an edit with a diff is open and the rest closed.
    @State private var toggled: Bool?

    private var isExpanded: Bool { toggled ?? (item.isFileEdit && item.toolDiff != nil) }

    static let accessibilityIdentifier = "toolCallRow"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                let open = !isExpanded
                withAnimation(.snappy(duration: 0.2)) { toggled = open }
            } label: {
                HStack(spacing: 6) {
                    statusIcon.frame(width: 14)
                    Text(ToolCallSummary.title(for: item))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if item.isFileEdit, let diff = item.toolDiff {
                        let stats = ToolCallDetail.stats(diff)
                        if stats.added > 0 { Text("+\(stats.added)").monospacedDigit().foregroundStyle(.green) }
                        if stats.removed > 0 { Text("−\(stats.removed)").monospacedDigit().foregroundStyle(.red) }
                    }
                    if let duration = item.tool?.durationSeconds, !item.isActive {
                        Text(Self.duration(duration)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            if isExpanded {
                ToolCallDetail(item: item)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if item.isActive {
            ProgressView().controlSize(.mini)
        } else if item.tool?.phase == .failed {
            Image(systemName: "xmark.circle").foregroundStyle(.red)
        } else {
            Image(systemName: "wrench.and.screwdriver").imageScale(.small)
        }
    }

    private var hasDetail: Bool { !ToolCallDetail.sections(for: item).isEmpty }

    static func duration(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s"
    }
}

/// What an opened tool call shows: its input, then its diff, output or error, each
/// capped so a huge result never lays out in full.
struct ToolCallDetail: View {
    let item: TranscriptItem

    struct Section: Identifiable {
        enum Kind { case input, output, diff, error }
        let kind: Kind
        let text: String
        var id: Kind { kind }
    }

    static let maxCharacters = 6000

    static func sections(for item: TranscriptItem) -> [Section] {
        let tool = item.tool
        var sections: [Section] = []
        // An edit's diff says what its arguments would, more readably.
        let input = tool?.args.map(inputText) ?? tool?.context ?? item.detail
        if let input, !input.isEmpty, !(item.isFileEdit && item.toolDiff != nil) {
            sections.append(Section(kind: .input, text: input))
        }
        if let error = tool?.error, !error.isEmpty {
            sections.append(Section(kind: .error, text: error))
        } else if let diff = item.toolDiff {
            sections.append(Section(kind: .diff, text: diff))
        } else if let output = tool?.output ?? tool?.summary, !output.isEmpty {
            sections.append(Section(kind: .output, text: output))
        }
        return sections
    }

    /// A single command or path reads as itself; anything else as its JSON.
    static func inputText(_ args: JSONValue) -> String {
        if case .object(let object) = args {
            for key in ["command", "code", "path", "query", "url"] {
                if let value = object[key]?.stringValue, object.count == 1 || key == "command" || key == "code" {
                    return value
                }
            }
        }
        if case .string(let text) = args { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(args)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.sections(for: item)) { section in
                text(section)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private func text(_ section: Section) -> some View {
        let capped = section.text.count > Self.maxCharacters
            ? String(section.text.prefix(Self.maxCharacters)) + "\n…"
            : section.text
        switch section.kind {
        case .input: Text(capped).foregroundStyle(.primary)
        case .output: Text(capped).foregroundStyle(.secondary)
        case .error: Text(capped).foregroundStyle(.red)
        case .diff: Text(Self.diff(capped))
        }
    }

    static func stats(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    static func diff(_ text: String) -> AttributedString {
        var result = AttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var piece = AttributedString(line + "\n")
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                piece.foregroundColor = .green
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                piece.foregroundColor = .red
            } else {
                piece.foregroundColor = .secondary
            }
            result += piece
        }
        return result
    }
}

/// A run of tool calls under one summary line, as Desktop's `ToolRun` draws it
/// (`components/assistant-ui/tool/fallback.tsx:950-1048`). Closed by default; while
/// live, the call in progress shows under the line. A run of one call is that call's
/// row, with no summary above it.
struct ToolRunView<Message: View>: View {
    let run: ToolRun
    @ViewBuilder let message: (TranscriptItem) -> Message
    @State private var isExpanded = false

    static var accessibilityIdentifier: String { "toolRunSummary" }

    var body: some View {
        let visible = run.visibleItems
        if visible.count == 1, let only = visible.first {
            message(only)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(visible) { message($0) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 1)
                    }
                } else if run.isLive, let current = run.tools.last {
                    message(current)
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(run.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

/// The transcript's rows as the chat shows them, in order:
/// - each block (`Transcript.blocks`): a message, drawn by `message` (a reply with
///   nothing to show yet is skipped: the waiting row stands in for it), or a run of
///   tool calls under its summary line;
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
        ForEach(transcript.blocks) { block in
            switch block {
            case .item(let item):
                if !item.isBlankReply {
                    message(item, item.id == newestID)
                }
            case .run(let run):
                ToolRunView(run: run) { item in
                    message(item, item.id == newestID)
                }
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
