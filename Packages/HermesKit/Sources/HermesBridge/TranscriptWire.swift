import Foundation
import HermesKit

/// The transcript as the Mac app lays it out (`TranscriptMessages`), for the desktop app:
/// its blocks (`Transcript.blocks`), each a message or a turn's work in three layers
/// (`TurnWork`: commentary, groups of steps, steps), and each tool call as `ToolCallView`
/// draws it. The app only lays these out; every decision is HermesKit's.
/// See docs/desktop-bridge.md, "Transcript".
enum TranscriptWire {
    /// A block: a message (`item`, an id in the snapshot's `items`) or a turn's work.
    struct Block: Encodable, Sendable, Equatable {
        var id: String
        var kind: String
        var item: String?
        var work: Work?

        init(_ block: TranscriptBlock) {
            id = block.id
            switch block {
            case .item(let item):
                kind = "item"
                self.item = item.id
            case .work(let work):
                kind = "work"
                self.work = Work(work)
            }
        }
    }

    /// A turn's work before its answer: "Working… 12s" while live, else `title`
    /// ("Completed in 45s"), opening to its entries.
    struct Work: Encodable, Sendable, Equatable {
        var isLive: Bool
        /// Unix seconds: when the turn's prompt was sent, when known.
        var startedAt: Double?
        /// Seconds, when both ends are known.
        var duration: Double?
        var interrupted: Bool
        /// The settled line (`TurnWork.settledTitle`).
        var title: String
        var entries: [Entry]

        init(_ work: TurnWork) {
            isLive = work.isLive
            startedAt = work.startedAt?.timeIntervalSince1970
            duration = work.duration
            interrupted = work.wasInterrupted
            title = TurnWork.settledTitle(duration: work.duration, interrupted: work.wasInterrupted)
            entries = work.entries.map(Entry.init)
        }
    }

    /// `commentary` (the model's text between steps) and `card` (a request card) name an
    /// item; `group` carries its steps.
    struct Entry: Encodable, Sendable, Equatable {
        var id: String
        var kind: String
        var item: String?
        var group: Group?

        init(_ entry: TurnWork.Entry) {
            id = entry.id
            switch entry {
            case .commentary(let item):
                kind = "commentary"
                self.item = item.id
            case .card(let item):
                kind = "card"
                self.item = item.id
            case .group(let group):
                kind = "group"
                self.group = Group(group)
            }
        }
    }

    /// Consecutive steps under one line ("Ran commands"); while live, its newest step's.
    struct Group: Encodable, Sendable, Equatable {
        var isLive: Bool
        var title: String
        /// What its calls did, for the line's tooltip.
        var summary: String
        /// The tool whose icon the line shows; none for reasoning alone.
        var iconTool: String?
        var steps: [Step]

        init(_ group: StepGroup) {
            isLive = group.isLive
            title = group.title
            summary = group.tools.isEmpty ? group.title : group.summary
            iconTool = group.iconTool
            steps = group.steps.map(Step.init)
        }
    }

    /// One step: "Bash · git status", "Think · Checking the build".
    struct Step: Encodable, Sendable, Equatable {
        var id: String
        /// `think` or `tool`.
        var kind: String
        /// The step's item, in the snapshot's `items`.
        var item: String
        var isLive: Bool
        /// The line's first word ("Bash", "Think").
        var label: String
        var summary: String
        var toolName: String?
        var failed: Bool
        var workdir: String?
        /// What the card's Copy copies.
        var copyText: String

        init(_ step: WorkStep) {
            id = step.id
            switch step {
            case .think: kind = "think"
            case .tool: kind = "tool"
            }
            item = step.item.id
            isLive = step.isLive
            label = step.kind
            summary = step.summary
            toolName = step.toolName
            failed = step.item.tool?.phase == .failed
            workdir = step.workdir
            copyText = step.copyText
        }
    }

    /// A tool call as `ToolCallView` draws it. Texts come clamped for display, a diff in
    /// its display form and output without ANSI codes, so the app paints them as they are.
    struct Tool: Encodable, Sendable, Equatable {
        struct Hit: Encodable, Sendable, Equatable {
            var title: String
            var url: String
            var snippet: String
        }

        var toolName: String
        var title: String
        /// `running`, `success`, `error`, `notice` or `warning`.
        var status: String
        var isPending: Bool
        var isFileEdit: Bool
        var isExpandable: Bool
        var opensByDefault: Bool
        var isHidden: Bool
        /// Whether a step's card has a body under its header (`WorkStepCard.hasBody`).
        var hasBody: Bool
        var showsDetail: Bool
        var rendersDetailAsCode: Bool
        var detail: String
        var detailLabel: String
        var errorSummary: String
        var detailBody: String
        var countLabel: String?
        var durationLabel: String?
        var inlineDiff: String
        /// The diff's added and removed line counts.
        var added: Int
        var removed: Int
        var searchQuery: String?
        var searchHits: [Hit]
        var stdout: String?
        var stderr: String?
        var terminalCommand: String?
        var terminalExitCode: Int?

        init(_ view: ToolCallView) {
            toolName = view.toolName
            title = view.title
            status = switch view.status {
            case .running: "running"
            case .success: "success"
            case .error: "error"
            case .notice: "notice"
            case .warning: "warning"
            }
            isPending = view.isPending
            isFileEdit = view.isFileEdit
            isExpandable = view.isExpandable
            opensByDefault = view.opensByDefault
            isHidden = view.isHidden
            hasBody = view.showsDetail || !view.detail.isEmpty || view.stdout != nil || view.stderr != nil
                || !view.searchHits.isEmpty || !view.inlineDiff.isEmpty
            showsDetail = view.showsDetail
            rendersDetailAsCode = view.rendersDetailAsCode
            let clamp = { ToolCallView.clampForDisplay($0) }
            detail = clamp(view.rendersDetailAsCode ? ToolCallView.stripANSI(view.detail) : view.detail)
            detailLabel = view.detailLabel
            errorSummary = view.errorSummary
            detailBody = clamp(view.detailBody)
            countLabel = view.countLabel
            durationLabel = view.durationLabel
            inlineDiff = clamp(view.inlineDiff.isEmpty ? "" : ToolCallSummary.displayDiff(view.inlineDiff))
            var added = 0, removed = 0
            for line in view.inlineDiff.split(separator: "\n") {
                if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
            }
            self.added = added
            self.removed = removed
            searchQuery = view.searchQuery
            searchHits = view.searchHits.map { Hit(title: $0.title, url: $0.url, snippet: $0.snippet) }
            stdout = view.stdout.map { clamp(ToolCallView.stripANSI($0)) }
            stderr = view.stderr.map { clamp(ToolCallView.stripANSI($0)) }
            terminalCommand = view.terminalCommand
            terminalExitCode = view.terminalExitCode
        }
    }

    /// The reply's stand-in while it is awaited (`Transcript.waiting`).
    struct Waiting: Encodable, Sendable, Equatable {
        var label: String
        var hint: String?
        /// Unix seconds: when the prompt was sent here.
        var since: Double?

        init(_ waiting: Transcript.Waiting) {
            label = waiting.label
            hint = waiting.hint
            since = waiting.since?.timeIntervalSince1970
        }
    }

    /// A background notice Hermes wrote as a user turn, or what the review saved.
    struct Note: Encodable, Sendable, Equatable {
        var headline: String
        var detail: String
    }
}
