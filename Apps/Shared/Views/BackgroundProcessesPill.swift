import HermesKit
import SwiftUI

/// The processes the chat's agent left running in the background
/// (`ChatSession.backgroundProcesses`), as Desktop's status stack lists them above its
/// composer (`apps/desktop/src/app/chat/composer/status-stack/`): a glass pill
/// ("1 background task") in the row over the composer (`ChatPillRow`), which opens into a
/// card as wide as the composer. Each row shows its command and how it ended; picked, its
/// newest output. A running one has Stop, a finished one goes by itself after a few
/// seconds, or with its ✕.
///
/// The card closes with a click or tap anywhere outside it (`dismissesOnOutsideTap`), so it
/// needs no close button of its own beside Stop (the user, 2026-11-06).
struct BackgroundProcessesPill: View {
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

enum BackgroundProcessesText {
    static func title(_ count: Int) -> String {
        count == 1 ? "1 background task" : "\(count) background tasks"
    }
}

struct BackgroundProcessesPanel: View {
    let session: ChatSession
    let processes: [BackgroundProcess]
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(BackgroundProcessesText.title(processes.count))
                .font(.body.weight(.medium))
                .monospacedDigit()
                .frame(minHeight: 28)
                .padding(.horizontal, 18)
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
