import HermesKit
import SwiftUI

extension View {
    /// The chat's scrolling around prompts: a prompt sent from the chat (Return, a
    /// slash command, a steer) brings it to the bottom, as ChatGPT does, wherever it
    /// was scrolled to. On macOS the prompt rail sits at its trailing edge.
    /// - Parameter proxy: the reader around the chat's scroll view; a rail tick
    ///   scrolls to its prompt's block with it.
    func promptScrolling(transcript: Transcript, proxy: ScrollViewProxy) -> some View {
        modifier(PromptScrolling(transcript: transcript, proxy: proxy))
    }
}

private struct PromptScrolling: ViewModifier {
    let transcript: Transcript
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
                    PromptRail(marks: marks) { mark in
                        if let id = transcript.blockID(containing: mark.id) {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                    .padding(.vertical, PromptRail.verticalInset)
                    .padding(.trailing, PromptRail.trailingInset)
                }
            }
            #endif
    }
}

/// A tick per prompt the user sent, oldest at the top, down the chat's trailing edge,
/// like the timeline beside Time Machine's windows. Hovering a tick shows its prompt
/// (the first line, cut short); clicking it scrolls the chat to that prompt and its reply.
struct PromptRail: View {
    let marks: [PromptMark]
    let select: (PromptMark) -> Void
    @State private var hovered: String?

    /// The rail's width. The chat's content leaves this much room beside it.
    static let width: CGFloat = 22
    /// Space between the rail and the chat's edge, clear of the scroller.
    static let trailingInset: CGFloat = 12
    /// Space above and below the rail, clear of the title bar and the composer.
    static let verticalInset: CGFloat = 24
    /// The room each tick gets at most: a long chat packs its ticks closer.
    static let maxSpacing: CGFloat = 14
    static let accessibilityIdentifier = "prompt-rail-tick"

    /// The height of each tick's row: `maxSpacing`, or less so `count` fit in `height`.
    static func spacing(count: Int, height: CGFloat) -> CGFloat {
        guard count > 0, height > 0 else { return maxSpacing }
        return min(maxSpacing, height / CGFloat(count))
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing = Self.spacing(count: marks.count, height: geometry.size.height)
            VStack(spacing: 0) {
                ForEach(marks) { mark in
                    tick(mark, height: spacing)
                        .zIndex(hovered == mark.id ? 1 : 0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(width: Self.width)
    }

    private func tick(_ mark: PromptMark, height: CGFloat) -> some View {
        let isHovered = hovered == mark.id
        return Button {
            select(mark)
        } label: {
            HStack {
                Spacer(minLength: 0)
                Capsule()
                    .fill(isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: isHovered ? 14 : 8, height: isHovered ? 3 : 2)
            }
            .frame(width: Self.width, height: height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = mark.id
            } else if hovered == mark.id {
                hovered = nil
            }
        }
        .overlay(alignment: .trailing) {
            if isHovered {
                Text(mark.label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .frame(width: 280, alignment: .trailing)
                    .offset(x: -Self.width)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(mark.label)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}
