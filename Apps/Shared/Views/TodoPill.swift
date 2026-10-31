import HermesKit
import SwiftUI

/// The agent's task list (`Transcript.todoPlan`), as Claude Code shows its own: a small
/// glass pill centered above the composer ("3/5 tasks"), which opens the whole list in a
/// popover, one line per task down a timeline, the done ones struck through. It goes with
/// the list: a finished list at the next prompt (`TodoPlan.current`).
///
/// A view of its own: it reads the transcript, which changes with every streamed word,
/// and only it redraws for that, not the composer under it.
struct TodoPill: View {
    let transcript: Transcript
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let accessibilityIdentifier = "todoPill"
    static let panelIdentifier = "todoPanel"

    var body: some View {
        let plan = transcript.todoPlan
        ZStack {
            if let plan {
                Label(plan: plan, isOpen: $isOpen)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 1.1).combined(with: .opacity).combined(with: .offset(y: 5)),
                        removal: .scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: 5))))
            }
        }
        .animation(Motion.jumpButton, value: plan == nil)
        .onChange(of: plan == nil) { _, gone in if gone { isOpen = false } }
    }

    private struct Label: View {
        let plan: TodoPlan
        @Binding var isOpen: Bool
        @State private var isHovered = false

        var body: some View {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    ProgressGlyph(done: plan.completed, total: plan.total, isFinished: plan.isFinished)
                    Text(TodoPill.title(plan))
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered || isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.leading, 9)
                .padding(.trailing, 12)
                .frame(height: 28)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .floatingGlass(in: .capsule, interactive: true)
            .animation(Motion.reveal, value: isHovered)
            .onHover { isHovered = $0 }
            .accessibilityLabel(TodoPill.accessibilityLabel(plan))
            .accessibilityHint("Shows the task list")
            .accessibilityIdentifier(TodoPill.accessibilityIdentifier)
            .help(TodoPill.accessibilityLabel(plan))
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                TodoPanel(plan: plan) { isOpen = false }
                    #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                    #endif
            }
        }
    }

    /// "3/5 tasks", as Claude Code's pill.
    static func title(_ plan: TodoPlan) -> String {
        "\(plan.completed)/\(plan.total) \(plan.total == 1 ? "task" : "tasks")"
    }

    static func accessibilityLabel(_ plan: TodoPlan) -> String {
        if plan.isFinished { return "All tasks complete, \(plan.completed) of \(plan.total)" }
        return "Tasks, \(plan.completed) of \(plan.total) complete"
    }
}

/// The pill's mark: a ring filling with the tasks done, a check once none is left.
private struct ProgressGlyph: View {
    let done: Int
    let total: Int
    let isFinished: Bool

    var body: some View {
        if isFinished {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white, Color.accentColor)
        } else {
            ZStack {
                Circle().stroke(.secondary.opacity(0.35), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: total > 0 ? CGFloat(done) / CGFloat(total) : 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            .padding(1)
        }
    }
}

/// The whole list: a title with the progress, then each task down a timeline.
struct TodoPanel: View {
    let plan: TodoPlan
    let close: () -> Void

    static let rowSpacing: CGFloat = 10
    static let glyphSize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(plan.isFinished ? "\(TodoPill.title(plan)) complete" : TodoPill.title(plan))
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: 12)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let rows = plan.rows
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        TodoRow(row: row, isLast: index == rows.count - 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 340)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(TodoPill.panelIdentifier)
    }
}

/// One task: its mark on the timeline, joined to the next one's by a line, and its text.
private struct TodoRow: View {
    let row: TodoPlan.Row
    let isLast: Bool

    private var status: TodoPlan.Status { row.item.status }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mark
                .frame(width: TodoPanel.glyphSize, height: TodoPanel.glyphSize)
                .padding(.top, 1)
                .frame(maxHeight: .infinity, alignment: .top)
                // The line runs from under this mark to the next one's.
                .background(alignment: .top) {
                    if !isLast {
                        Rectangle()
                            .fill(.secondary.opacity(0.3))
                            .frame(width: 1.5)
                            .padding(.top, TodoPanel.glyphSize + 3)
                            .padding(.bottom, -2)
                    }
                }
            Text(row.item.content)
                .font(.callout.weight(status == .inProgress ? .semibold : .regular))
                .strikethrough(status == .completed || status == .cancelled)
                .foregroundStyle(status == .completed || status == .cancelled ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, isLast ? 0 : TodoPanel.rowSpacing)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.statusText(status))
    }

    @ViewBuilder private var mark: some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white, Color.accentColor)
        case .inProgress:
            ZStack {
                Circle().stroke(Color.accentColor, lineWidth: 1.5)
                Circle().fill(Color.accentColor).padding(4)
            }
            .padding(1)
        case .pending:
            Circle().stroke(.secondary.opacity(0.6), lineWidth: 1.5).padding(1)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    static func statusText(_ status: TodoPlan.Status) -> String {
        switch status {
        case .completed: "Done"
        case .inProgress: "In progress"
        case .pending: "Not started"
        case .cancelled: "Cancelled"
        }
    }
}
