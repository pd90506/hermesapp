import HermesKit
import SwiftUI

/// The processes the chat's agent left running in the background
/// (`ChatSession.backgroundProcesses`), as Desktop's status stack lists them above its
/// composer (`apps/desktop/src/app/chat/composer/status-stack/`): a glass pill
/// ("1 background task") like the subagents' (`SubagentsPill`), which opens into a card.
/// Each row shows its command and how it ended; picked, its newest output. A running one
/// has Stop, a finished one goes by itself after a few seconds, or with its ✕.
///
/// It reads the gateway's registry when the chat shows, then every 5 s while a process
/// runs (Desktop's `BACKGROUND_POLL_MS`); `ChatSession` reads it too after the tools that
/// start or reap one, and when the gateway announces one finished.
struct BackgroundProcessesPill: View {
    let session: ChatSession
    /// False while the chat is kept built but hidden: no polling then.
    var isShown = true
    @Binding var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let processes = session.backgroundProcesses.processes
        let running = processes.contains(where: \.isRunning)
        ZStack(alignment: .bottom) {
            if !processes.isEmpty {
                if isOpen {
                    GlassEffectContainer(spacing: 0) {
                        BackgroundProcessesPanel(session: session, processes: processes) { isOpen = false }
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                } else {
                    GlassEffectContainer(spacing: 0) { BackgroundProcessesPillLabel(processes: processes, isOpen: $isOpen) }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .padding(.bottom, processes.isEmpty ? 0 : 8)
        .animation(Motion.jumpButton, value: processes.isEmpty)
        .animation(Motion.swap, value: isOpen)
        .onChange(of: processes.isEmpty) { _, gone in if gone { isOpen = false } }
        .task(id: "\(session.sessionID):\(isShown):\(running)") {
            guard isShown else { return }
            await session.refreshBackgroundProcesses()
            while running, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await session.refreshBackgroundProcesses()
            }
        }
    }
}

enum BackgroundProcessesText {
    static func title(_ count: Int) -> String {
        count == 1 ? "1 background task" : "\(count) background tasks"
    }
}

private struct BackgroundProcessesPillLabel: View {
    let processes: [BackgroundProcess]
    @Binding var isOpen: Bool
    @State private var isHovered = false

    var body: some View {
        let running = processes.filter(\.isRunning).count
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(processes.contains { $0.state == .failed } ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Text(BackgroundProcessesText.title(running > 0 ? running : processes.count))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .floatingGlass(in: .capsule, interactive: true)
        .animation(Motion.reveal, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel(running > 0 ? "\(BackgroundProcessesText.title(running)) running"
                                        : BackgroundProcessesText.title(processes.count))
        .accessibilityHint("Shows the background tasks")
        .accessibilityIdentifier("backgroundProcessesPill")
        .help(processes.map(\.title).joined(separator: "\n"))
    }

    /// An outline while one runs, as the session row's dot (`ChatStatusDot`).
    private var symbol: String {
        if processes.contains(where: \.isRunning) { return "circle.dashed" }
        return processes.contains { $0.state == .failed } ? "xmark.circle" : "checkmark.circle"
    }
}

private struct BackgroundProcessesPanel: View {
    let session: ChatSession
    let processes: [BackgroundProcess]
    let close: () -> Void
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(BackgroundProcessesText.title(processes.count))
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
                .accessibilityIdentifier("backgroundProcessesClose")
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(processes) { process in
                        BackgroundProcessRow(session: session, process: process, isPicked: picked == process.id) {
                            picked = picked == process.id ? nil : process.id
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
        .accessibilityIdentifier("backgroundProcessesPanel")
    }
}

/// A process: its state, command and Stop (running) or ✕ (finished); picked, its output.
private struct BackgroundProcessRow: View {
    let session: ChatSession
    let process: BackgroundProcess
    let isPicked: Bool
    let toggle: () -> Void
    @State private var isStopping = false
    @State private var stopFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: toggle) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        stateIcon
                            .frame(width: 16)
                        Text(process.title)
                            .font(.callout.monospaced())
                            .lineLimit(isPicked ? 4 : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let exitCode = process.exitCode, process.state == .failed {
                            Text("exit \(exitCode)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                        if process.output != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isPicked ? 90 : 0))
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("backgroundProcessRow")
                if process.isRunning {
                    Button("Stop", role: .destructive, action: stop)
                        .controlSize(.small)
                        .disabled(isStopping)
                        .accessibilityIdentifier("backgroundProcessStop")
                } else {
                    Button("Dismiss", systemImage: "xmark") { session.dismissBackgroundProcess(process.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            if stopFailed {
                Text("Hermes couldn't stop it. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if isPicked, let output = process.output {
                Text(output.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
            }
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch process.state {
        case .running:
            ProgressView().controlSize(.small)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        case .done:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle").foregroundStyle(.red)
        }
    }

    private func stop() {
        isStopping = true
        stopFailed = false
        Task {
            defer { isStopping = false }
            do { try await session.stopBackgroundProcess(process.id) } catch { stopFailed = true }
        }
    }
}
