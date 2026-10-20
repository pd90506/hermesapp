import HermesKit
import SwiftUI

/// The chat's floating "scroll to bottom" control, as Desktop's (`ScrollToBottomButton`):
/// a small glass pill centered just above the composer, shown only while the chat is
/// scrolled well up from its end (`ChatScroll.isAwayFromEnd`). It reads "Scroll to bottom"
/// with a down arrow, or how many messages are below the screen ("3 messages",
/// `MessagesBelow`). It comes in from a little larger and goes out to a little smaller,
/// and a click or tap scrolls the chat smoothly down to the newest message.
///
/// A view of its own, as the prompt rail: it reads the blocks on screen, which change as
/// the chat scrolls, and only it redraws for them.
struct ScrollToBottomButton: View {
    let transcript: Transcript
    let scroll: ChatScroll
    let visibleBlocks: VisibleBlocks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let accessibilityIdentifier = "scrollToBottom"

    var body: some View {
        // At the end, nothing else is read: a reply streaming in doesn't redraw it.
        let isShown = scroll.isAwayFromEnd
        ZStack {
            if isShown {
                Pill(count: transcript.messagesBelow(visibleBlockIDs: visibleBlocks.ids)) {
                    scroll.scrollToEnd(reduceMotion: reduceMotion)
                }
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .scale(scale: 1.1).combined(with: .opacity).combined(with: .offset(y: 5)),
                    removal: .scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: 5))))
            }
        }
        .animation(Motion.jumpButton, value: isShown)
    }

    private struct Pill: View {
        let count: Int
        let action: () -> Void
        @State private var isHovered = false
        @Environment(\.surfaces) private var surfaces
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(MessagesBelow.title(count: count))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            // Liquid Glass in the theme's composer colour, as the composer card on iPhone,
            // with the same hairline edge: Desktop's pill is the composer's fill, blurred.
            .glassEffect(.regular.tint(surfaces.composer.opacity(colorScheme == .dark ? 0.55 : 0.4)).interactive(),
                         in: .capsule)
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            .animation(Motion.swap, value: count)
            .animation(Motion.reveal, value: isHovered)
            .onHover { isHovered = $0 }
            .accessibilityLabel(MessagesBelow.accessibilityLabel(count: count))
            .accessibilityIdentifier(ScrollToBottomButton.accessibilityIdentifier)
            .help(MessagesBelow.scrollToBottom)
        }
    }
}
