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
    /// Branch in New Chat from this reply; without it the bar has no "…" menu.
    var branch: (() -> Void)?
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
                MessageActionBar(isHovering: isHovering, isNewest: isNewest, timestamp: item.timestamp,
                                 branch: branch, copy: copy)
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
    @Remembered private var isExpanded: Bool

    static let accessibilityIdentifier = "reasoningToggle"

    init(item: TranscriptItem, isExpanded: Bool = false) {
        self.item = item
        _isExpanded = Remembered(wrappedValue: isExpanded, "reasoning:\(item.id)")
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

/// The line every fold in the chat opens with (reasoning, a tool call, a turn's work, a
/// group of its steps, a step): its label, then a chevron. The whole line is the button.
/// Opening or closing keeps the chat's scroll place (`ChatScroll.keepingPlace`), so the
/// line stays under the pointer and the next click closes it again. On the Mac the pointer
/// over a line that opens is a pointing hand, as over a link (the user, 2026-10-18).
struct FoldButton<Label: View>: View {
    enum Chevron {
        /// Points right, turning down while open.
        case disclosure
        /// Points down, and up while open: a turn's "Completed in" line.
        case upDown
        /// A disclosure chevron shown only while the pointer is over the line: a turn's
        /// groups and steps, which read as plain lines.
        case onHover
        case none
    }

    @Binding var isExpanded: Bool
    var chevron = Chevron.disclosure
    @ViewBuilder let label: Label
    @Environment(\.chatScroll) private var chatScroll
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(isExpanded: Binding<Bool>, showsChevron: Bool = true, @ViewBuilder label: () -> Label) {
        self.init(isExpanded: isExpanded, chevron: showsChevron ? .disclosure : .none, label: label)
    }

    init(isExpanded: Binding<Bool>, chevron: Chevron, @ViewBuilder label: () -> Label) {
        _isExpanded = isExpanded
        self.chevron = chevron
        self.label = label()
    }

    var body: some View {
        Button {
            let open = !isExpanded
            let toggle = { withAnimation(.snappy(duration: 0.2)) { isExpanded = open } }
            if let chatScroll { chatScroll.keepingPlace(toggle) } else { toggle() }
        } label: {
            HStack(spacing: 6) {
                label
                switch chevron {
                case .disclosure, .onHover:
                    Image(systemName: "chevron.right")
                        .uiFont(.caption2, weight: .semibold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .opacity(chevron == .onHover && !isHovering ? 0 : 1)
                case .upDown:
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .uiFont(.caption2, weight: .semibold)
                        .foregroundStyle(.tertiary)
                case .none:
                    EmptyView()
                }
                Spacer(minLength: 0)
            }
            .uiFont(.callout)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pointerStyle(isEnabled ? .link : nil)
        #endif
        .onHover { isHovering = $0 }
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
    @Remembered private var toggled: Bool?

    static let accessibilityIdentifier = "toolCallRow"

    init(item: TranscriptItem, isExpanded: Bool? = nil) {
        self.item = item
        _toggled = Remembered(wrappedValue: isExpanded, "tool:\(item.id)")
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
    /// False where the command is shown above the body already (`WorkStepCard`).
    var showsCommand = true
    /// Shows the output even where it repeats the call's line (`ToolCallView.showsDetail`):
    /// a step's card is where its output is read.
    var showsAllOutput = false
    /// Output past this many lines scrolls; nil for `ToolTextBox`'s own limit.
    var outputMaxLines: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsCommand, let command = view.terminalCommand, !command.isEmpty || view.terminalExitCode != nil {
                TerminalCommandLine(command: command, exitCode: view.terminalExitCode)
            }
            if !view.searchHits.isEmpty {
                SearchHitList(query: view.searchQuery, hits: view.searchHits)
            }
            if !view.inlineDiff.isEmpty {
                ToolTextBox(text: view.inlineDiff, kind: .diff)
            }
            if view.showsDetail || (showsAllOutput && view.inlineDiff.isEmpty && !view.detail.isEmpty) { detail }
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
                    ToolTextBox(text: ToolCallView.stripANSI(stdout), kind: .code, maxLines: outputMaxLines)
                }
                if let stderr = view.stderr {
                    ToolSectionLabel(text: "stderr")
                    ToolTextBox(text: ToolCallView.stripANSI(stderr), kind: .code, maxLines: outputMaxLines, isMuted: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ToolSectionLabel(text: view.detailLabel)
                if view.rendersDetailAsCode {
                    ToolTextBox(text: ToolCallView.stripANSI(view.detail), kind: .code, maxLines: outputMaxLines)
                } else {
                    ToolTextBox(text: view.detail, kind: .text, maxLines: outputMaxLines)
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
    @Remembered private var isExpanded: Bool

    static let accessibilityIdentifier = "backgroundNotice"

    /// - Parameter id: the notice's row, under which the chat remembers it open.
    init(notice: BackgroundNotice, id: String) {
        self.notice = notice
        _isExpanded = Remembered(wrappedValue: false, "notice:\(id)")
    }

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

/// A turn's work before its answer (`TurnWork`), in the three layers the user asked
/// for: one line, "Completed in 45s" (live: "Working… 12s"), with a thin rule under it
/// and the answer below; opened, under the rule, the turn's commentary and groups of
/// steps, several when the model wrote between them; a group
/// opened, its steps, each opening in place to a card. Open one layer (its groups and text,
/// groups closed) while the turn works, closed once it is done, until the user opens or closes it.
struct TurnWorkView<Message: View>: View {
    let work: TurnWork
    @ViewBuilder let message: (TranscriptItem) -> Message
    /// The user's choice; until then open exactly while the turn works.
    @Remembered private var toggled: Bool?
    /// When this view saw the work end, for a turn whose rows carry no time yet.
    @Remembered private var settledAt: Date?
    /// For a turn this chat did not send: count from when the line appeared.
    @State private var appeared = Date()

    static var accessibilityIdentifier: String { "turnWorkSummary" }

    init(work: TurnWork, isExpanded: Bool? = nil, @ViewBuilder message: @escaping (TranscriptItem) -> Message) {
        self.work = work
        self.message = message
        _toggled = Remembered(wrappedValue: isExpanded, "work:\(work.id)")
        _settledAt = Remembered(wrappedValue: nil, "work-settled:\(work.id)")
    }

    var body: some View {
        let isOpen = toggled ?? work.isLive
        VStack(alignment: .leading, spacing: 8) {
            FoldButton(isExpanded: Binding(get: { isOpen }, set: { toggled = $0 }), chevron: .upDown) {
                title
            }
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            Divider()
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(work.entries) { entry in
                        switch entry {
                        case .commentary(let item), .card(let item): message(item)
                        case .group(let group): StepGroupView(group: group)
                        }
                    }
                }
            }
        }
        .onChange(of: work.isLive) { _, isLive in settledAt = isLive ? nil : Date() }
    }

    @ViewBuilder private var title: some View {
        if work.isLive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Working… \(Transcript.Waiting.elapsedText(from: work.startedAt ?? appeared, to: context.date))")
                    .monospacedDigit()
            }
        } else {
            Text(TurnWork.settledTitle(duration: duration, interrupted: work.wasInterrupted))
                .monospacedDigit()
        }
    }

    /// The stored rows' time, else from the prompt sent here to when the work ended here.
    private var duration: TimeInterval? {
        if let duration = work.duration { return duration }
        guard let start = work.startedAt, let settledAt, settledAt >= start else { return nil }
        return settledAt.timeIntervalSince(start)
    }
}

/// A group of a turn's steps: its kind's icon and what its calls did ("Ran commands"),
/// a chevron only under the pointer; opened, its steps one line each. Closed until the
/// user opens it, also while the turn works in it (the user, 2026-10-18: a working turn
/// opens one layer, its groups and text). While the turn works in it, its line is its
/// newest step's ("Skill · hermes-agent", then "Bash · git status"), changing as each
/// step starts; once the turn moves on, it reads what the calls did ("Called tools, ran
/// commands").
struct StepGroupView: View {
    let group: StepGroup
    @Remembered private var isExpanded: Bool

    static let accessibilityIdentifier = "workGroupRow"

    init(group: StepGroup, isExpanded: Bool = false) {
        self.group = group
        _isExpanded = Remembered(wrappedValue: isExpanded, "group:\(group.id)")
    }

    /// The step the group's line shows: its newest, while the turn works in it.
    static func liveStep(of group: StepGroup) -> WorkStep? {
        group.isLive ? group.steps.last : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FoldButton(isExpanded: $isExpanded, chevron: .onHover) {
                if let latest = Self.liveStep(of: group) {
                    WorkStepLine(step: latest)
                } else {
                    Image(systemName: group.iconTool.map(ToolCallLine.icon) ?? WorkStepLine.thinkIcon)
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    Text(group.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .help(group.tools.isEmpty ? group.title : group.summary)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.steps) { WorkStepView(step: $0) }
                }
                .padding(.leading, 20)
            }
        }
    }
}

/// One step: "Bash · git status", "Think · Checking the build", opening in place to
/// its card (`WorkStepCard`).
struct WorkStepView: View {
    let step: WorkStep
    @Remembered private var isExpanded: Bool

    static let accessibilityIdentifier = "workStepRow"

    init(step: WorkStep, isExpanded: Bool = false) {
        self.step = step
        _isExpanded = Remembered(wrappedValue: isExpanded, "step:\(step.id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FoldButton(isExpanded: $isExpanded, chevron: .onHover) {
                WorkStepLine(step: step)
            }
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            if isExpanded {
                WorkStepCard(step: step)
            }
        }
    }
}

/// A step's line: its icon (or its status while it runs or once it failed), its kind,
/// a dot, and what it was about, cut short at the end.
struct WorkStepLine: View {
    let step: WorkStep

    static let thinkIcon = "atom"

    var body: some View {
        HStack(spacing: 6) {
            glyph.frame(width: 14)
            Text(step.kind)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            if !step.summary.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(step.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.tertiary)
            }
        }
        .uiFont(.callout)
    }

    private var failed: Bool { step.item.tool?.phase == .failed }

    @ViewBuilder private var glyph: some View {
        if step.isLive {
            ProgressView().controlSize(.mini)
        } else if failed {
            Image(systemName: "exclamationmark.circle").imageScale(.small).foregroundStyle(.red)
        } else {
            Image(systemName: step.toolName.map(ToolCallLine.icon) ?? Self.thinkIcon)
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
    }
}

/// An opened step, the bottom layer, as the user's screenshot draws it: a rounded card
/// whose top holds a status dot, the working folder (or the call's title), the whole
/// command in a monospaced font and a Copy button; under a rule, the output in a
/// monospaced font, scrolling past a few lines. A call that is not a command shows its
/// Desktop title and what it opens to (`ToolCallBody`); reasoning shows in full.
struct WorkStepCard: View {
    let step: WorkStep
    @Environment(\.sessionFolder) private var sessionFolder

    static let accessibilityIdentifier = "workStepCard"
    /// Output past this many lines scrolls inside the card.
    static let outputMaxLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .think(let item):
                header { Text("Reasoning").uiFont(.caption).foregroundStyle(.tertiary) }
                Divider()
                ReasoningText(item: item)
                    .padding(8)
            case .tool(let item):
                let view = ToolCallView(item)
                header { toolHeading(view) }
                if Self.hasBody(view) {
                    Divider()
                    ToolCallBody(view: view, showsCommand: false, showsAllOutput: true,
                                 outputMaxLines: Self.outputMaxLines)
                        .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }

    private func header<Heading: View>(@ViewBuilder _ heading: () -> Heading) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StepStatusDot(step: step)
                .padding(.top, 4)
            heading()
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(step.copyText) }
                .labelStyle(.titleAndIcon)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .hoverButtonStyle(.rounded, padding: 3)
                .help("Copy")
                .accessibilityIdentifier("workStepCopy")
        }
        .padding(8)
    }

    @ViewBuilder private func toolHeading(_ view: ToolCallView) -> some View {
        if let command = view.terminalCommand {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let folder = Self.folderName(step.workdir ?? sessionFolder) {
                        Text(folder).uiFont(.caption).foregroundStyle(.tertiary)
                    }
                    if let exitCode = view.terminalExitCode, exitCode != 0 {
                        Text("exit \(exitCode)")
                            .uiFont(.caption2, design: .monospaced)
                            .foregroundStyle(.orange)
                    }
                    if !view.isPending, let duration = view.durationLabel {
                        Text(duration).uiFont(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                Text(command.isEmpty ? step.summary : command)
                    .uiFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 6) {
                Text(view.title)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !view.isPending, let count = view.countLabel {
                    Text(count).uiFont(.caption).foregroundStyle(.tertiary)
                }
                if !view.isPending, let duration = view.durationLabel {
                    Text(duration).uiFont(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The call shows something under its header: output, hits, a diff or an error.
    static func hasBody(_ view: ToolCallView) -> Bool {
        view.showsDetail || !view.detail.isEmpty || view.stdout != nil || view.stderr != nil || !view.searchHits.isEmpty || !view.inlineDiff.isEmpty
    }

    /// The last part of a folder's path, as the card names it.
    static func folderName(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        let parts = path.split(separator: "/")
        return parts.last.map(String.init) ?? path
    }
}

/// A step's status in its card: running, done, failed or a warning.
private struct StepStatusDot: View {
    let step: WorkStep

    var body: some View {
        if step.isLive {
            ProgressView().controlSize(.mini)
        } else {
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }

    private var color: Color {
        guard case .tool(let item) = step else { return .secondary }
        switch ToolCallView(item).status {
        case .error: return .red
        case .warning: return .orange
        case .notice: return .secondary
        case .running, .success: return .green
        }
    }
}

extension EnvironmentValues {
    /// The session's working folder (`session.info`'s `cwd`): a command's card names it
    /// when the call did not name its own.
    @Entry var sessionFolder: String? = nil
}

/// The transcript's rows as the chat shows them, in order:
/// - each block (`Transcript.blocks`): a message, drawn by `message` (a reply with
///   nothing to show yet is skipped: the waiting row stands in for it), or a turn's
///   work under its "Completed in" line (`TurnWorkView`);
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
    @Environment(\.transcriptWindow) private var window

    var body: some View {
        let newestID = ConversationMarkdown.newestMessageID(in: transcript.items)
        let blocks = transcript.blocks
        ForEach(blocks[(window?.start(in: blocks) ?? 0)...]) { block in
            Group {
                switch block {
                case .item(let item):
                    if !item.isBlankReply {
                        message(item, item.id == newestID)
                    }
                case .work(let work):
                    TurnWorkView(work: work) { item in
                        message(item, item.id == newestID)
                    }
                }
            }
            .nearScreen()
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

/// Which of a chat's blocks `TranscriptMessages` builds (`PaintBudget`): when the chat
/// comes on screen, a screen of the newest; then, a frame at a time, the older ones
/// above them, until the whole transcript is built. The chat keeps its bottom as they
/// land (`defaultScrollAnchor`), so the rows on screen stay where they are.
///
/// A chat opened before its rows are read starts again once they land, so a page read
/// over the network is built the same way.
///
/// On iPhone a chat is a page pushed over the session list, and the push waits for the
/// page's first layout: a long reply's rows held it back by most of a second (a reply
/// of tables and code was 390 text views, VM 2026-10-18). There the window builds no
/// row until the push is over (`pushed`), then only the newest block, then the rest.
@MainActor @Observable final class TranscriptWindow {
    enum Extent: Equatable {
        /// Nothing yet: the page is being pushed.
        case none
        /// The first frame: `PaintBudget.firstPaintStart`.
        case firstPaint
        /// The blocks from this index on.
        case from(Int)
        case all
    }

    private(set) var extent: Extent
    /// The page is pushed: no rows until the push is over, then the newest block alone.
    private let pushed: Bool

    init(pushed: Bool = false) {
        self.pushed = pushed
        extent = pushed ? .none : .firstPaint
    }

    /// About as long as the system's push.
    static let pushDuration = Duration.milliseconds(350)

    /// Every block is built.
    var isComplete: Bool { extent == .all }

    /// Rows are waiting for the push to end.
    var isWaitingForPush: Bool { extent == .none }

    /// The index of the first block built.
    func start(in blocks: [TranscriptBlock]) -> Int {
        switch extent {
        case .none: blocks.count
        case .firstPaint:
            pushed ? PaintBudget.start(in: blocks, end: blocks.count, budget: PaintBudget.firstPaint, minimumBlocks: 1)
                : PaintBudget.firstPaintStart(in: blocks)
        case .from(let index): min(index, blocks.count)
        case .all: 0
        }
    }

    /// Builds the older blocks above the first frame's, a step a frame.
    fileprivate func backfill(_ blocks: @MainActor () -> [TranscriptBlock]) async {
        if extent == .none {
            try? await Task.sleep(for: Self.pushDuration)
            guard !Task.isCancelled else { return }
            extent = .firstPaint
        }
        var start = start(in: blocks())
        while start > 0 {
            // A frame for the rows already shown, and for input between the steps.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            let all = blocks()
            start = PaintBudget.start(in: all, end: min(start, all.count), budget: PaintBudget.step)
            extent = start > 0 ? .from(start) : .all
        }
        extent = .all
    }

    /// No rows yet: they are built from the first frame again once they land.
    fileprivate func restart() { extent = .firstPaint }
}

extension EnvironmentValues {
    /// The blocks `TranscriptMessages` builds; nil builds all of them.
    @Entry var transcriptWindow: TranscriptWindow? = nil
}

extension View {
    /// Builds the transcript in this view newest first (`TranscriptWindow`). `blocks`
    /// reads the transcript's blocks as they are now.
    func transcriptWindow(_ window: TranscriptWindow?, isEmpty: Bool,
                          blocks: @escaping @MainActor () -> [TranscriptBlock]) -> some View {
        environment(\.transcriptWindow, window)
            .task(id: isEmpty) {
                guard let window else { return }
                if isEmpty {
                    window.restart()
                } else {
                    await window.backfill(blocks)
                }
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
