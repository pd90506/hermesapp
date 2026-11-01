import HermesKit
import SwiftUI

/// The chat's running subagents (`ChatSession.subagents`), as Desktop's status stack
/// lists them above its composer: a glass pill ("2 subagents", spinning) centered above
/// the composer, beside nothing else, which opens into a card as wide as the composer.
/// Each child shows its goal, what it did last and how long it has run; picked, its
/// newest lines, a field to steer it and Stop. It goes once no child runs.
///
/// A view of its own: subagent events change only `ChatSession.subagents`, so only it
/// redraws for them. It reconciles with the gateway's roster while the chat shows,
/// every 5 s while a turn runs or a child does (Desktop polls every 5 s).
struct SubagentsPill: View {
    let session: ChatSession
    /// False while the chat is kept built but hidden: no polling then.
    var isShown = true
    @Binding var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = session.subagents.live
        ZStack(alignment: .bottom) {
            if !live.isEmpty {
                if isOpen {
                    GlassEffectContainer(spacing: 0) {
                        SubagentsPanel(session: session, runs: live) { isOpen = false }
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                } else {
                    GlassEffectContainer(spacing: 0) { SubagentsPillLabel(runs: live, isOpen: $isOpen) }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        // The gap to the task list's pill or the card under it, only while it shows.
        .padding(.bottom, live.isEmpty ? 0 : 8)
        .animation(Motion.jumpButton, value: live.isEmpty)
        .animation(Motion.swap, value: isOpen)
        .onChange(of: live.isEmpty) { _, gone in if gone { isOpen = false } }
        .task(id: "\(session.sessionID):\(isShown)") {
            guard isShown else { return }
            // Children that outlived a reload or another client's turn show at once.
            await session.refreshSubagents()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if session.transcript.isRunning || !session.subagents.live.isEmpty {
                    await session.refreshSubagents()
                }
            }
        }
    }
}

enum SubagentsText {
    static func title(_ count: Int) -> String {
        count == 1 ? "1 subagent" : "\(count) subagents"
    }
}

private struct SubagentsPillLabel: View {
    let runs: [SubagentRun]
    @Binding var isOpen: Bool
    @State private var isHovered = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(SubagentsText.title(runs.count))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .floatingGlass(in: .capsule, interactive: true)
        .animation(Motion.reveal, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(SubagentsText.title(runs.count)) running")
        .accessibilityHint("Shows the subagents")
        .accessibilityIdentifier("subagentsPill")
        .help(runs.map(\.goal).joined(separator: "\n"))
    }
}

/// Every running child, one row each; the picked one opens under its row.
private struct SubagentsPanel: View {
    let session: ChatSession
    let runs: [SubagentRun]
    let close: () -> Void
    @State private var picked: String?
    /// What is typed to steer each child, kept while another is picked.
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(SubagentsText.title(runs.count))
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
                .accessibilityIdentifier("subagentsClose")
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(runs) { run in
                        SubagentRow(run: run, isPicked: picked == run.id) {
                            picked = picked == run.id ? nil : run.id
                        }
                        if picked == run.id {
                            SubagentDetail(session: session, run: run, draft: Binding(
                                get: { drafts[run.id] ?? "" }, set: { drafts[run.id] = $0 }))
                                .padding(.leading, 24)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingGlass(in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagentsPanel")
        .onChange(of: runs.map(\.id)) { _, ids in
            if let picked, !ids.contains(picked) { self.picked = nil }
        }
    }
}

/// A child: spinning, its goal, its newest line, and how long it has run.
private struct SubagentRow: View {
    let run: SubagentRun
    let isPicked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.goal)
                        .lineLimit(isPicked ? 4 : 1)
                    Text(latest)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Counts up by itself, from when the child started.
                Text(run.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isPicked ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isPicked ? "Hides its details" : "Shows what it did, and Steer and Stop")
        .accessibilityIdentifier("subagentRow")
    }

    private var latest: String {
        if let line = run.activity.last?.text { return line }
        return run.status == .queued ? "Queued" : "Waiting for activity…"
    }
}

/// A picked child: its newest lines, then a field to steer it and Stop.
private struct SubagentDetail: View {
    let session: ChatSession
    let run: SubagentRun
    @Binding var draft: String
    @State private var isSending = false
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !run.activity.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(run.activity.suffix(6).enumerated()), id: \.offset) { _, line in
                        Label {
                            Text(line.text).lineLimit(2)
                        } icon: {
                            Image(systemName: Self.symbol(line.kind))
                        }
                        .font(.caption)
                        .foregroundStyle(line.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }
                .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                TextField("Steer this subagent…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(steer)
                    .disabled(isSending)
                    .accessibilityIdentifier("subagentSteerField")
                Button("Steer", action: steer)
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop", role: .destructive, action: stop)
                    .disabled(isSending)
                    .accessibilityIdentifier("subagentStop")
            }
            .controlSize(.small)
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
    }

    private func steer() {
        let text = draft
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(done: "It will read that with its next tool result.") {
            let queued = try await session.steerSubagent(run.id, text: text)
            if queued { draft = "" }
            return queued
        }
    }

    private func stop() {
        send(done: "Asked it to stop.") { try await session.stopSubagent(run.id) }
    }

    private func send(done: String, _ call: @escaping @MainActor () async throws -> Bool) {
        isSending = true
        feedback = nil
        Task {
            defer { isSending = false }
            let accepted = (try? await call()) ?? false
            failed = !accepted
            feedback = accepted ? done : "Hermes didn't accept that: the subagent may have finished."
        }
    }

    private static func symbol(_ kind: SubagentRun.Activity.Kind) -> String {
        switch kind {
        case .tool: "wrench.and.screwdriver"
        case .progress: "arrow.forward"
        case .thinking: "brain"
        case .summary: "text.alignleft"
        }
    }
}
