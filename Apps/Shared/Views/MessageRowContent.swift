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
    /// Draws files the reply delivers (`MEDIA:` tags), where their tags were
    /// (`MediaTags.segments`); the tags themselves are not shown. Without it the
    /// files are left out.
    var deliveredFiles: (([DeliveredFile]) -> AnyView)?
    let copy: () -> Void
    @Environment(\.isInToolRun) private var isInToolRun

    /// No text (whitespace counts as none, as for the waiting row and the action bar),
    /// no reasoning and no outcome to show: the row has no content yet.
    static func isBlank(_ item: TranscriptItem) -> Bool { item.isBlankReply }

    /// The reply as Markdown runs and the files delivered between them. Text without
    /// a tag is one run, as it was (whitespace-only text is none).
    static func segments(_ item: TranscriptItem) -> [MediaTags.Segment] {
        guard item.text.contains(MediaTags.prefix) else {
            return item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.markdown(item.text)]
        }
        return MediaTags.segments(item.text, isStreaming: item.isActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !item.reasoning.isEmpty {
                    // Inside an opened run it is shown as it is: the run is the fold.
                    if isInToolRun {
                        ReasoningText(item: item)
                    } else {
                        ReasoningFold(item: item)
                    }
                }
                ForEach(Array(Self.segments(item).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let text):
                        MarkdownView(text: text, isStreaming: item.isActive, conversationSource: conversationSource)
                            .equatable()
                    case .files(let files):
                        if let deliveredFiles { deliveredFiles(files) }
                    }
                }
                if item.outcome == "interrupted" {
                    Text("Interrupted").uiFont(.caption).foregroundStyle(.secondary)
                }
            }
            // Directly under the message, so moving down onto it never leaves the row.
            if ConversationMarkdown.hasActionBar(item) {
                MessageActionBar(isHovering: isHovering, isNewest: isNewest, copy: copy)
            }
        }
    }
}

/// A reply's reasoning, closed under a "Reasoning" line. The whole line opens it, the
/// word as well as the chevron, and it opens below the line, which stays where it was.
/// Model-written like the reply, so rendered the same way; the content is only built
/// while open.
struct ReasoningFold: View {
    let item: TranscriptItem
    @State private var isExpanded: Bool

    static let accessibilityIdentifier = "reasoningToggle"

    init(item: TranscriptItem, isExpanded: Bool = false) {
        self.item = item
        _isExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FoldButton(isExpanded: $isExpanded) {
                Text("Reasoning")
            }
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            if isExpanded {
                ReasoningText(item: item)
            }
        }
    }
}

/// Reasoning as it reads once shown: smaller than the reply, in the secondary color.
struct ReasoningText: View {
    let item: TranscriptItem

    var body: some View {
        MarkdownView(text: item.reasoning, isStreaming: item.isActive, isReasoning: true)
            .equatable()
    }
}

/// The line every fold in the chat opens with (reasoning, a tool call, a run of them):
/// its label, then a chevron that turns down while open. The whole line is the button.
/// Opening or closing holds the chat's scroll position (`ChatScrollAnchor.hold(then:)`), so
/// the line stays under the pointer and the next click closes it again.
struct FoldButton<Label: View>: View {
    @Binding var isExpanded: Bool
    var showsChevron = true
    @ViewBuilder let label: Label
    @Environment(\.chatScrollAnchor) private var scrollAnchor

    var body: some View {
        Button {
            let open = !isExpanded
            let toggle = { withAnimation(.snappy(duration: 0.2)) { isExpanded = open } }
            if let scrollAnchor { scrollAnchor.hold(then: toggle) } else { toggle() }
        } label: {
            HStack(spacing: 6) {
                label
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .uiFont(.caption2, weight: .semibold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .uiFont(.callout)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

extension EnvironmentValues {
    /// Drawn inside an opened run of tool calls (`ToolRunView`): the run is the one
    /// fold, so nothing in it folds again. Reasoning shows as it is, and a tool call's
    /// input and output open in a popover rather than below its line.
    @Entry var isInToolRun = false
}

/// One tool call, as Desktop draws it: a single line (status, what it did, chevron)
/// that opens on demand to the call's input, output, diff or error. A file edit
/// with a diff opens by default, with its +/− counts on the line. No action bar
/// (Copy Message is in its context menu), so a run of tool calls stays compact.
///
/// Inside an opened run (`isInToolRun`) the line doesn't fold: a click shows the
/// call's input and output in a popover beside it, so a run never opens into folds
/// of its own.
struct ToolMessageContent: View {
    let item: TranscriptItem
    /// The user's choice; until then an edit with a diff is open and the rest closed.
    @State private var toggled: Bool?
    @State private var showsPopover = false
    @Environment(\.isInToolRun) private var isInToolRun

    private var isExpanded: Bool { toggled ?? (item.isFileEdit && item.toolDiff != nil) }

    static let accessibilityIdentifier = "toolCallRow"
    static let popoverWidth: CGFloat = 520

    var body: some View {
        if isInToolRun {
            HStack(spacing: 0) {
                Button {
                    showsPopover = true
                } label: {
                    line
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .hoverHighlight(isEnabled: hasDetail)
                        .padding(.horizontal, -4)
                        .padding(.vertical, -1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!hasDetail)
                .help(hasDetail ? "Show input and output" : "")
                .accessibilityIdentifier(Self.accessibilityIdentifier)
                .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                    // Each box scrolls inside itself past `ToolCallDetail.maxLines`.
                    ToolCallDetail(item: item)
                        .padding(12)
                        .frame(width: Self.popoverWidth)
                        .presentationCompactAdaptation(.popover)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                FoldButton(isExpanded: Binding(get: { isExpanded }, set: { toggled = $0 }),
                           showsChevron: hasDetail) {
                    line
                }
                .disabled(!hasDetail)
                .accessibilityIdentifier(Self.accessibilityIdentifier)
                if isExpanded {
                    ToolCallDetail(item: item)
                        .padding(.leading, 20)
                }
            }
        }
    }

    /// Status, what the call did, and its counts and duration.
    private var line: some View {
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
        }
        .uiFont(.callout)
        .foregroundStyle(.secondary)
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
    let sections: [Section]

    init(item: TranscriptItem) { sections = Self.sections(for: item) }
    init(sections: [Section]) { self.sections = sections }

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
            ForEach(sections) { section in
                box(section)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            }
        }
    }

    /// The most lines a box shows before it scrolls inside itself, as Desktop's diff
    /// box stops at 12rem (`components/chat/diff-lines.tsx:67`).
    static let maxLines = 12
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 15
    @Environment(\.textSizes) private var sizes

    @ViewBuilder private func box(_ section: Section) -> some View {
        let content = text(section)
            .uiFont(.caption, design: .monospaced)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        if Self.lineCount(Self.shown(section)) > Self.maxLines {
            ScrollView(.vertical) { content }
                .frame(height: lineHeight * sizes.uiScale * CGFloat(Self.maxLines) + 16)
                .accessibilityIdentifier("toolDetailScroll")
        } else {
            content
        }
    }

    static func lineCount(_ text: String) -> Int {
        text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// What a section shows: a diff without its headers.
    static func shown(_ section: Section) -> String {
        section.kind == .diff ? ToolCallSummary.displayDiff(section.text) : section.text
    }

    @ViewBuilder private func text(_ section: Section) -> some View {
        let shown = Self.shown(section)
        let capped = shown.count > Self.maxCharacters
            ? String(shown.prefix(Self.maxCharacters)) + "\n…"
            : shown
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
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((index > 0 ? "\n" : "") + line)
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

/// A background notice Hermes wrote as a user turn (`BackgroundNotice`): one line, as
/// Desktop's `BackgroundResult` shows it, opening to the command and output.
struct BackgroundNoticeRow: View {
    let notice: BackgroundNotice
    @State private var isExpanded = false

    static let accessibilityIdentifier = "backgroundNotice"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FoldButton(isExpanded: $isExpanded, showsChevron: !notice.detail.isEmpty) {
                Image(systemName: "bell").imageScale(.small).frame(width: 14)
                Text(notice.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .disabled(notice.detail.isEmpty)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            if isExpanded {
                ToolCallDetail(sections: [.init(kind: .output, text: notice.detail)])
                    .padding(.leading, 20)
            }
        }
    }
}

/// A run of tool calls under one summary line, as Desktop's `ToolRun` draws it
/// (`components/assistant-ui/tool/fallback.tsx:950-1048`). Closed by default; while
/// live, the call in progress shows under the line. A run of one call is that call's
/// row, with no summary above it.
///
/// The run is the one fold: what it opens to doesn't fold again (`isInToolRun`).
struct ToolRunView<Message: View>: View {
    let run: ToolRun
    @ViewBuilder let message: (TranscriptItem) -> Message
    @State private var isExpanded: Bool

    static var accessibilityIdentifier: String { "toolRunSummary" }

    init(run: ToolRun, isExpanded: Bool = false, @ViewBuilder message: @escaping (TranscriptItem) -> Message) {
        self.run = run
        self.message = message
        _isExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        let visible = run.visibleItems
        if visible.count == 1, let only = visible.first {
            message(only)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                FoldButton(isExpanded: $isExpanded) {
                    Text(run.summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityIdentifier(Self.accessibilityIdentifier)
                Group {
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
                .environment(\.isInToolRun, true)
            }
        }
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

    @Environment(\.visibleBlocks) private var visibleBlocks

    var body: some View {
        let newestID = ConversationMarkdown.newestMessageID(in: transcript.items)
        ForEach(transcript.blocks) { block in
            Group {
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
            .modifier(BlockVisibility(id: block.id, blocks: visibleBlocks))
        }
        let waiting = transcript.waiting
        if let waiting {
            ResponseWaitingRow(waiting: waiting)
        }
        requests()
        if waiting == nil, let status = transcript.status, transcript.isRunning {
            Label(status, systemImage: "ellipsis")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
        }
        if let lastError = transcript.lastError {
            Label(lastError, systemImage: "exclamationmark.triangle")
                .uiFont(.callout)
                .foregroundStyle(.red)
        }
    }
}

/// The blocks of `TranscriptMessages` on screen, by id. The chat uses them for the
/// prompt it is at (`PromptRail`). A class, so the environment holds one stable
/// reference rather than a closure that changes on every update.
@MainActor @Observable final class VisibleBlocks {
    private(set) var ids: Set<String> = []

    func set(_ id: String, visible: Bool) {
        if visible { ids.insert(id) } else { ids.remove(id) }
    }
}

extension EnvironmentValues {
    /// Where `TranscriptMessages` reports which of its blocks are on screen, when set.
    @Entry var visibleBlocks: VisibleBlocks? = nil
}

/// Reports a block's visibility to `visibleBlocks`, when one is set.
private struct BlockVisibility: ViewModifier {
    let id: String
    let blocks: VisibleBlocks?

    func body(content: Content) -> some View {
        if let blocks {
            content
                .onScrollVisibilityChange(threshold: 0.01) { blocks.set(id, visible: $0) }
                .onDisappear { blocks.set(id, visible: false) }
        } else {
            content
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
