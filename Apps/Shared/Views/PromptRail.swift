import HermesKit
import SwiftUI

extension View {
    /// The chat's scrolling around prompts: a prompt sent from the chat (Return, a
    /// slash command, a steer) brings it to the bottom, as ChatGPT does, wherever it
    /// was scrolled to. On macOS the prompt rail sits at its trailing edge.
    /// - Parameters:
    ///   - current: the prompt the chat is at (`Transcript.currentPromptID`), marked on the rail.
    ///   - proxy: the reader around the chat's scroll view; the rail scrolls to a
    ///     prompt's block with it.
    func promptScrolling(transcript: Transcript, current: String? = nil, proxy: ScrollViewProxy) -> some View {
        modifier(PromptScrolling(transcript: transcript, current: current, proxy: proxy))
    }
}

private struct PromptScrolling: ViewModifier {
    let transcript: Transcript
    let current: String?
    let proxy: ScrollViewProxy
    @State private var position = ScrollPosition(idType: String.self)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: transcript.lastPromptID) { _, id in
                guard id != nil else { return }
                position.scrollTo(edge: .bottom)
            }
            #if os(macOS)
            .overlay(alignment: .trailing) {
                let marks = transcript.promptMarks
                if !marks.isEmpty {
                    PromptRail(marks: marks, current: current) { mark in
                        PromptRail.scroll(to: mark, in: transcript, with: proxy)
                    }
                    .padding(.vertical, PromptRail.verticalInset)
                    .padding(.trailing, PromptRail.trailingInset)
                }
            }
            #endif
    }
}

/// A tick per prompt the user sent, oldest at the top, down the chat's trailing edge,
/// like the timeline beside Time Machine's windows; the prompt the chat is at is the
/// long dark one. Hovering the rail opens a panel over it, as Notion's outline does,
/// listing every prompt (one line each); it opens level with the rail's top, scrolls
/// when the chat has more than fit, and opens scrolled to the prompt the chat is at.
/// Clicking a tick or a prompt scrolls the chat to that prompt and its reply.
struct PromptRail: View {
    let marks: [PromptMark]
    var current: String?
    let select: (PromptMark) -> Void
    @State private var overRail = false
    @State private var overPanel = false
    @State private var isOpen = false

    /// The rail's width.
    static let width: CGFloat = 22
    /// Space between the rail and the chat's edge, clear of the scroller.
    static let trailingInset: CGFloat = 28
    /// Space above and below the rail, clear of the title bar and the composer.
    static let verticalInset: CGFloat = 24
    /// The room the chat's content leaves at each side for the rail.
    static let room: CGFloat = width + trailingInset
    /// The room each tick gets at most: a long chat packs its ticks closer.
    static let maxSpacing: CGFloat = 14
    static let panelWidth: CGFloat = 280
    /// The panel's tallest; a longer list scrolls.
    static let panelMaxHeight: CGFloat = 420
    /// About how tall a panel row is, to place the panel before it is laid out.
    static let panelRowEstimate: CGFloat = 26
    static let accessibilityIdentifier = "prompt-rail-tick"
    static let rowIdentifier = "prompt-rail-row"

    /// What a tick does: scrolls the prompt's block (the prompt and its reply) to the top.
    static func scroll(to mark: PromptMark, in transcript: Transcript, with proxy: ScrollViewProxy) {
        if let id = transcript.blockID(containing: mark.id) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// The height of each tick's row: `maxSpacing`, or less so `count` fit in `height`.
    static func spacing(count: Int, height: CGFloat) -> CGFloat {
        guard count > 0, height > 0 else { return maxSpacing }
        return min(maxSpacing, height / CGFloat(count))
    }

    /// Where the panel's top goes in a rail `height` tall: level with the first tick, so
    /// the panel opens in place of the ticks rather than beside one of them; kept inside
    /// the rail.
    static func panelTop(count: Int, height: CGFloat) -> CGFloat {
        let ticksTop = (height - spacing(count: count, height: height) * CGFloat(count)) / 2
        let panel = min(panelMaxHeight, height, CGFloat(count) * panelRowEstimate + 16)
        return max(0, min(ticksTop, height - panel))
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let spacing = Self.spacing(count: marks.count, height: height)
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    ForEach(marks) { mark in
                        tick(mark, height: spacing)
                    }
                }
                .frame(width: Self.width, height: height)
                .opacity(isOpen ? 0 : 1)
                .onHover { overRail = $0 }
                if isOpen {
                    panel(maxHeight: min(Self.panelMaxHeight, height))
                        .offset(y: Self.panelTop(count: marks.count, height: height))
                        .onHover { overPanel = $0 }
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topTrailing)
        }
        // Wide enough for the panel while it is open, so it takes the pointer there.
        .frame(width: isOpen ? Self.panelWidth : Self.width)
        .task(id: overRail || overPanel) {
            let hovering = overRail || overPanel
            // A short wait before closing, so moving between the rail and the panel
            // (which opens over it) does not close it.
            if !hovering { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { isOpen = hovering }
        }
    }

    private func tick(_ mark: PromptMark, height: CGFloat) -> some View {
        let isCurrent = mark.id == current
        return Button {
            select(mark)
        } label: {
            HStack {
                Spacer(minLength: 0)
                Capsule()
                    .fill(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: isCurrent ? 16 : 10, height: 2)
            }
            .frame(width: Self.width, height: height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mark.label)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }

    private func panel(maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(marks) { mark in
                        PanelRow(mark: mark, isCurrent: mark.id == current) { select(mark) }
                            .id(mark.id)
                    }
                }
                .padding(8)
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
        // As tall as its rows, up to `maxHeight`; then it scrolls.
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Self.panelWidth)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// A prompt in the rail's panel: its label on one line; the one the chat is at
/// in the accent color, the hovered one on a light background.
private struct PanelRow: View {
    let mark: PromptMark
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(mark.label)
                .font(.callout)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(PromptRail.rowIdentifier)
    }
}
