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
                    ReasoningFold(item: item)
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
/// Opening or closing keeps the chat's scroll place (`ChatScroll.keepingPlace`), so the
/// line stays under the pointer and the next click closes it again.
struct FoldButton<Label: View>: View {
    @Binding var isExpanded: Bool
    var showsChevron = true
    @ViewBuilder let label: Label
    @Environment(\.chatScroll) private var chatScroll

    var body: some View {
        Button {
            let open = !isExpanded
            let toggle = { withAnimation(.snappy(duration: 0.2)) { isExpanded = open } }
            if let chatScroll { chatScroll.keepingPlace(toggle) } else { toggle() }
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

/// One tool call, as Desktop's `ToolEntry` draws it (`components/assistant-ui/tool/fallback.tsx:309-760`):
/// a line (status or tool glyph, what it did, counts and duration, chevron) that opens
/// in place into a bordered card: a command's `$` line and output, a file's lines, search
/// hits, a diff or an error. An edit with a diff opens by default; a settled edit with
/// no diff draws nothing. What each part says comes from `ToolCallView`.
struct ToolMessageContent: View {
    let item: TranscriptItem
    /// The user's choice; until then an edit with a diff is open and the rest closed.
    @State private var toggled: Bool?

    static let accessibilityIdentifier = "toolCallRow"

    init(item: TranscriptItem, isExpanded: Bool? = nil) {
        self.item = item
        _toggled = State(initialValue: isExpanded)
    }

    var body: some View {
        let view = ToolCallView(item)
        let isOpen = (toggled ?? view.opensByDefault) && view.isExpandable
        if !view.isHidden {
            VStack(alignment: .leading, spacing: 0) {
                FoldButton(isExpanded: Binding(get: { isOpen }, set: { toggled = $0 }),
                           showsChevron: view.isExpandable) {
                    ToolCallLine(view: view)
                }
                .disabled(!view.isExpandable)
                .accessibilityIdentifier(Self.accessibilityIdentifier)
                .padding(.horizontal, isOpen ? 8 : 0)
                .padding(.vertical, isOpen ? 5 : 0)
                if isOpen {
                    Divider()
                    ToolCallBody(view: view)
                        .padding(6)
                }
            }
            .overlay {
                if isOpen { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary) }
            }
        }
    }
}

/// A tool call's line: its glyph, title, result count, diff counts and duration.
struct ToolCallLine: View {
    let view: ToolCallView

    var body: some View {
        HStack(spacing: 6) {
            glyph.frame(width: 14)
            Text(view.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(titleStyle)
            if !view.isPending, let count = view.countLabel {
                Text(count).foregroundStyle(.tertiary)
            }
            if view.isFileEdit, !view.isPending, !view.inlineDiff.isEmpty {
                let stats = ToolTextBox.stats(view.inlineDiff)
                if stats.added > 0 { Text("+\(stats.added)").monospacedDigit().foregroundStyle(.green) }
                if stats.removed > 0 { Text("−\(stats.removed)").monospacedDigit().foregroundStyle(.red) }
            }
            if !view.isFileEdit, !view.isPending, let duration = view.durationLabel {
                Text(duration).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .uiFont(.callout)
    }

    private var titleStyle: AnyShapeStyle {
        if view.isPending { return AnyShapeStyle(.tertiary) }
        switch view.status {
        case .error: return AnyShapeStyle(.red)
        case .warning: return AnyShapeStyle(.orange)
        default: return AnyShapeStyle(.secondary)
        }
    }

    /// A running, failed or unfinished call shows its status; any other its tool's icon.
    @ViewBuilder private var glyph: some View {
        if view.isPending {
            ProgressView().controlSize(.mini)
        } else if view.status == .error {
            Image(systemName: "exclamationmark.circle").imageScale(.small).foregroundStyle(.red)
        } else if view.status == .warning {
            Image(systemName: "exclamationmark.circle").imageScale(.small).foregroundStyle(.orange)
        } else {
            Image(systemName: Self.icon(view.toolName)).imageScale(.small).foregroundStyle(.tertiary)
        }
    }

    /// Desktop's tool icons (`TOOL_META`, `fallback-model/index.ts:144-219`) as SF Symbols.
    static func icon(_ name: String) -> String {
        switch name {
        case "read_file": "doc"
        case "list_files": "folder"
        case "search_files", "web_search", "session_search_recall": "magnifyingglass"
        case "terminal", "execute_code": "terminal"
        case "edit_file", "patch", "write_file": "doc.text"
        case "browser_take_screenshot", "image_generate": "photo"
        case "clarify": "questionmark.circle"
        case "cronjob": "clock"
        case "memory": "brain"
        case "todo": "checklist"
        case "vision_analyze": "eye"
        default: name.hasPrefix("browser_") || name.hasPrefix("web_") ? "globe" : "wrench.and.screwdriver"
        }
    }
}

/// What an opened tool call shows, in Desktop's order: the `$` command, search hits,
/// the diff, then the detail (an error, a command's streams, or the output).
struct ToolCallBody: View {
    let view: ToolCallView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command = view.terminalCommand, !command.isEmpty || view.terminalExitCode != nil {
                TerminalCommandLine(command: command, exitCode: view.terminalExitCode)
            }
            if !view.searchHits.isEmpty {
                SearchHitList(query: view.searchQuery, hits: view.searchHits)
            }
            if !view.inlineDiff.isEmpty {
                ToolTextBox(text: view.inlineDiff, kind: .diff)
            }
            if view.showsDetail { detail }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var detail: some View {
        if view.status == .error {
            VStack(alignment: .leading, spacing: 4) {
                if !view.errorSummary.isEmpty {
                    Text(view.errorSummary)
                        .uiFont(.caption, weight: .medium)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !view.detailBody.isEmpty {
                    ToolTextBox(text: view.detailBody, kind: .code, maxLines: ToolTextBox.errorMaxLines)
                }
            }
        } else if view.stdout != nil || view.stderr != nil {
            VStack(alignment: .leading, spacing: 4) {
                ToolSectionLabel(text: view.detailLabel)
                if let stdout = view.stdout {
                    if view.stderr != nil { ToolSectionLabel(text: "stdout") }
                    ToolTextBox(text: ToolCallView.stripANSI(stdout), kind: .code)
                }
                if let stderr = view.stderr {
                    ToolSectionLabel(text: "stderr")
                    ToolTextBox(text: ToolCallView.stripANSI(stderr), kind: .code, isMuted: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ToolSectionLabel(text: view.detailLabel)
                if view.rendersDetailAsCode {
                    ToolTextBox(text: ToolCallView.stripANSI(view.detail), kind: .code)
                } else {
                    ToolTextBox(text: view.detail, kind: .text)
                }
            }
        }
    }
}

/// A small heading over a section of an opened call ("stdout", "Error details").
struct ToolSectionLabel: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text.uppercased())
                .uiFont(.caption2, weight: .medium)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
    }
}

/// `$ command` and its exit code, above a terminal call's output.
struct TerminalCommandLine: View {
    let command: String
    let exitCode: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !command.isEmpty {
                Text("\(Text("$").foregroundStyle(.tint)) \(Text(command).foregroundStyle(.secondary))")
                    .uiFont(.caption, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let exitCode {
                Text("exit \(exitCode)")
                    .uiFont(.caption2, design: .monospaced)
                    .monospacedDigit()
                    .foregroundStyle(exitCode == 0 ? .green : .orange)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: .rect(cornerRadius: 3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quinary, in: .rect(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary) }
    }
}

/// A web search's hits: the query, then each hit's title (a link) and snippet.
struct SearchHitList: View {
    let query: String?
    let hits: [ToolCallView.SearchHit]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let query {
                Text("\(Text("Search").foregroundStyle(.tertiary)) \(query)")
                    .uiFont(.caption)
            }
            ToolSectionLabel(text: "Search results")
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 1) {
                    if let url = URL(string: hit.url), !hit.url.isEmpty {
                        Link(hit.title.isEmpty ? hit.url : hit.title, destination: url)
                            .uiFont(.caption, weight: .medium)
                            .lineLimit(1)
                    } else {
                        Text(hit.title).uiFont(.caption, weight: .medium)
                    }
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet).uiFont(.caption2).foregroundStyle(.tertiary).lineLimit(3)
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// A block of a call's text: code or output in a monospaced font, a diff in its colors,
/// other details as text. Past `maxLines` it scrolls inside itself: Desktop stops a
/// payload at 5rem (`TOOL_SECTION_SURFACE_CLASS`, `fallback.tsx:107-110`), a diff at
/// 12rem (`components/chat/diff-lines.tsx:67`) and an error at 14rem.
struct ToolTextBox: View {
    enum Kind { case code, text, diff }

    let text: String
    let kind: Kind
    var maxLines: Int?
    var isMuted = false

    static let outputMaxLines = 5
    static let diffMaxLines = 12
    static let errorMaxLines = 14

    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 15
    @Environment(\.textSizes) private var sizes

    init(text: String, kind: Kind, maxLines: Int? = nil, isMuted: Bool = false) {
        self.text = text
        self.kind = kind
        self.maxLines = maxLines
        self.isMuted = isMuted
    }

    private var limit: Int { maxLines ?? (kind == .diff ? Self.diffMaxLines : Self.outputMaxLines) }

    private var shown: String {
        ToolCallView.clampForDisplay(kind == .diff ? ToolCallSummary.displayDiff(text) : text)
    }

    var body: some View {
        let shown = self.shown
        let content = styled(shown)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        if Self.lineCount(shown) > limit {
            ScrollView(.vertical) { content }
                .frame(height: lineHeight * sizes.uiScale * CGFloat(limit) + 8)
                .accessibilityIdentifier("toolDetailScroll")
        } else {
            content
        }
    }

    @ViewBuilder private func styled(_ shown: String) -> some View {
        switch kind {
        case .code:
            Text(shown).uiFont(.caption, design: .monospaced).foregroundStyle(isMuted ? .tertiary : .secondary)
        case .text:
            Text(shown).uiFont(.caption).foregroundStyle(.secondary)
        case .diff:
            Text(Self.diff(shown)).uiFont(.caption, design: .monospaced)
        }
    }

    static func lineCount(_ text: String) -> Int {
        text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
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
                ToolTextBox(text: notice.detail, kind: .code, maxLines: ToolTextBox.diffMaxLines)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    .padding(.leading, 20)
            }
        }
    }
}

/// A run of consecutive tool calls under one summary line, as Desktop's `ToolRun` draws
/// it (`components/assistant-ui/tool/fallback.tsx:993-1048`). Closed by default; while
/// live, the call in progress shows under the line. A run of one call is that call's
/// row, with no summary above it. Opened, its calls are listed as they are, each one
/// opening in place.
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
                if isExpanded {
                    ForEach(visible) { message($0) }
                } else if run.isLive, let current = run.tools.last {
                    message(current)
                }
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
