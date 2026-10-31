import HermesKit
import SwiftUI

/// The agent's task list (`Transcript.todoPlan`), as Claude Code shows its own: a small
/// glass pill centered above the composer ("3/5 tasks"), which opens into a glass card as
/// wide as the composer, one line per task down a timeline, the done ones struck through.
/// It goes with the list: a finished list at the next prompt (`TodoPlan.current`).
///
/// A view of its own: it reads the transcript, which changes with every streamed word,
/// and only it redraws for that, not the composer under it.
struct TodoPill<Jump: View>: View {
    let transcript: Transcript
    let scroll: ChatScroll
    @Binding var isOpen: Bool
    /// The chat's scroll-to-bottom pill, beside this one while the chat is scrolled up
    /// (`ChatScroll.isAwayFromEnd`): one row of pills, never one over the other.
    @ViewBuilder let jump: () -> Jump
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let plan = transcript.todoPlan
        let showsJump = scroll.isAwayFromEnd
        ZStack(alignment: .bottom) {
            if let plan {
                if isOpen {
                    ownGlass { TodoPanel(plan: plan) { isOpen = false } }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                } else {
                    ownGlass { pills(plan, showsJump: showsJump) }
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 1.1).combined(with: .opacity).combined(with: .offset(y: 5)),
                            removal: .scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: 5))))
                }
            }
        }
        .animation(Motion.jumpButton, value: plan == nil)
        .animation(Motion.jumpButton, value: showsJump)
        .animation(Motion.swap, value: isOpen)
        .onChange(of: plan == nil) { _, gone in if gone { isOpen = false } }
    }

    /// A glass container of its own, with no room to merge: in the chat's (`ChatView`),
    /// whose glass merges shapes 16 pt apart so the scroll pill grows out of the composer,
    /// these pills and the composer under them ran together into one shape (the user,
    /// 2026-10-31). One for the pills and one for the card, not one around both: on the
    /// Mac the pill then kept the card's frame for accessibility once the card closed.
    private func ownGlass(@ViewBuilder _ content: () -> some View) -> some View {
        GlassEffectContainer(spacing: 0, content: content)
    }

    /// The row: the scroll-to-bottom pill (when it shows), then this one.
    private func pills(_ plan: TodoPlan, showsJump: Bool) -> some View {
        HStack(spacing: 8) {
            if showsJump {
                jump()
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
            TodoPillLabel(plan: plan, isOpen: $isOpen)
        }
    }
}

enum TodoPillID {
    static let pill = "todoPill"
    static let panel = "todoPanel"
}

enum TodoPillText {
    /// "3/5 tasks", as Claude Code's pill.
    static func title(_ plan: TodoPlan) -> String {
        "\(plan.completed)/\(plan.total) \(plan.total == 1 ? "task" : "tasks")"
    }

    static func accessibilityLabel(_ plan: TodoPlan) -> String {
        if plan.isFinished { return "All tasks complete, \(plan.completed) of \(plan.total)" }
        return "Tasks, \(plan.completed) of \(plan.total) complete"
    }
}

private struct TodoPillLabel: View {
    let plan: TodoPlan
    @Binding var isOpen: Bool
    @State private var isHovered = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                ProgressGlyph(done: plan.completed, total: plan.total, isFinished: plan.isFinished)
                Text(TodoPillText.title(plan))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isHovered || isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .floatingGlass(in: .capsule, interactive: true)
        .animation(Motion.reveal, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel(TodoPillText.accessibilityLabel(plan))
        .accessibilityHint("Shows the task list")
        .accessibilityIdentifier(TodoPillID.pill)
        .help(TodoPillText.accessibilityLabel(plan))
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

/// The whole list: a title with the progress and a close button over a line, then each
/// task down a timeline. A glass card as wide as the composer under it, as Claude Code's.
struct TodoPanel: View {
    let plan: TodoPlan
    let close: () -> Void

    static let rowSpacing: CGFloat = 14
    static let glyphSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(plan.isFinished ? "\(TodoPillText.title(plan)) complete" : TodoPillText.title(plan))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                Spacer(minLength: 12)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("todoClose")
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let rows = plan.rows
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        TodoRow(row: row, isLast: index == rows.count - 1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingGlass(in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TodoPillID.panel)
    }
}

/// One task: its mark on the timeline, joined to the next one's by a line, and its text.
private struct TodoRow: View {
    let row: TodoPlan.Row
    let isLast: Bool

    private var status: TodoPlan.Status { row.item.status }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark
                .frame(width: TodoPanel.glyphSize, height: TodoPanel.glyphSize)
                .frame(maxHeight: .infinity, alignment: .top)
                // The line runs from under this mark to the next one's.
                .background(alignment: .top) {
                    if !isLast {
                        Rectangle()
                            .fill(.secondary.opacity(0.45))
                            .frame(width: 1.5)
                            .padding(.top, TodoPanel.glyphSize + 4)
                            .padding(.bottom, 4)
                    }
                }
            Text(row.item.content)
                .padding(.top, 1)
                .font(.body.weight(status == .inProgress ? .semibold : .regular))
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
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor.opacity(0.18), in: .circle)
        case .inProgress:
            Circle()
                .fill(Color.accentColor)
                .padding(6)
                .background(Color.accentColor.opacity(0.18), in: .circle)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
        case .pending:
            Circle().stroke(.secondary.opacity(0.5), lineWidth: 1.5).padding(1)
        case .cancelled:
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.secondary.opacity(0.15), in: .circle)
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
