import HermesKit
import SwiftUI

/// The row of small glass pills just above the composer, centered: the scroll-to-bottom
/// arrow while the chat is scrolled up (`ChatScroll.isAwayFromEnd`), the background tasks
/// (`BackgroundProcessesPill`) and the task list (`TodoPillLabel`). One row, never one pill
/// over another (the user, 2026-10-31 and 2026-11-06). The task list opens into a card over
/// the row; the background tasks into a popover.
///
/// A view of its own: it reads the transcript, which changes with every streamed word, and
/// only it redraws for that, not the composer under it. While neither pill shows, the
/// scroll-to-bottom pill floats over the chat instead (`ChatView.chat`).
///
/// It also reads the background tasks' registry when the chat shows, then every 5 s while a
/// process runs (Desktop's `BACKGROUND_POLL_MS`); `ChatSession` reads it too after the tools
/// that start or reap one, and when the gateway announces one finished.
struct ChatPillRow: View {
    let session: ChatSession
    let scroll: ChatScroll
    let visibleBlocks: VisibleBlocks
    /// False while the chat is kept built but hidden: no polling then.
    var isShown = true
    @Binding var isTodoOpen: Bool
    @Binding var isProcessesOpen: Bool
    /// The composer's width: the popover goes no wider, so it fits an iPhone.
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let plan = session.transcript.todoPlan
        let processes = session.backgroundProcesses.processes
        let running = processes.contains(where: \.isRunning)
        let showsPills = (plan != nil && !isTodoOpen) || !processes.isEmpty
        let showsJump = scroll.isAwayFromEnd
        VStack(spacing: 8) {
            if let plan, isTodoOpen {
                ownGlass { TodoPanel(plan: plan) { isTodoOpen = false } }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
            }
            if showsPills {
                ownGlass { pills(plan: plan, processes: processes, showsJump: showsJump) }
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 1.1).combined(with: .opacity).combined(with: .offset(y: 5)),
                        removal: .scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: 5))))
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .animation(Motion.jumpButton, value: plan == nil)
        .animation(Motion.jumpButton, value: processes.isEmpty)
        .animation(Motion.jumpButton, value: showsJump)
        .animation(Motion.swap, value: isTodoOpen)
        .onChange(of: plan == nil) { _, gone in if gone { isTodoOpen = false } }
        .onChange(of: processes.isEmpty) { _, gone in if gone { isProcessesOpen = false } }
        .onChange(of: isShown) { _, shown in if !shown { isProcessesOpen = false } }
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

    /// A glass container of its own, with no room to merge: in the chat's (`ChatView`),
    /// whose glass merges shapes 16 pt apart so the scroll pill grows out of the composer,
    /// these pills and the composer under them ran together into one shape (the user,
    /// 2026-10-31). One for the pills and one for the card, not one around both: on the
    /// Mac the pill then kept the card's frame for accessibility once the card closed.
    private func ownGlass(@ViewBuilder _ content: () -> some View) -> some View {
        GlassEffectContainer(spacing: 0, content: content)
    }

    private func pills(plan: TodoPlan?, processes: [BackgroundProcess], showsJump: Bool) -> some View {
        HStack(spacing: 8) {
            if showsJump {
                // Just the arrow, in a circle, as Claude Code's (the user, 2026-10-31).
                ScrollToBottomButton(transcript: session.transcript, scroll: scroll, visibleBlocks: visibleBlocks,
                                     compact: true)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
            if !processes.isEmpty {
                BackgroundProcessesPill(session: session, processes: processes, maxWidth: width,
                                        isOpen: $isProcessesOpen)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
            if let plan, !isTodoOpen {
                TodoPillLabel(plan: plan, isOpen: $isTodoOpen)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }
}
