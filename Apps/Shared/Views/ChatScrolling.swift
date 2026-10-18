import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The chat's rows, one under the other. Every row is laid out, not only those on
/// screen: a lazy stack guessed the height of the rows it had not laid out yet and
/// corrected the guess as they scrolled in (a reply's real height, a table sized to its
/// first layout), so the content's height changed while scrolling and the scroller's
/// knob jumped. A page is at most `ChatSession.pageSize` messages, and a closed tool
/// run or reasoning fold builds nothing inside it.
struct TranscriptStack<Content: View>: View {
    static var spacing: CGFloat { 12 }
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            content
        }
    }
}

extension View {
    /// The chat's column: at most `maxWidth` wide, `sideRoom` clear of each edge, centered
    /// in `outerWidth`, the scroll view's own width. Its width and place come from that
    /// width alone, so they stay the same whether or not a scroller takes part of it.
    ///
    /// Centered in the scroll view's content instead, the column moved and rewrapped when
    /// a fold opened or closed: with a mouse connected, macOS shows a scroller that takes
    /// 16 pt once the content outgrows the screen, and takes it back once it fits (the
    /// user, 2026-10-18; the content's right edge moved 16 pt in the VM). The column now
    /// leaves that much room for a scroller always.
    func steadyColumn(maxWidth: CGFloat, sideRoom: CGFloat, in outerWidth: CGFloat?) -> some View {
        modifier(SteadyColumn(maxWidth: maxWidth, sideRoom: sideRoom, outerWidth: outerWidth))
    }
}

struct SteadyColumn: ViewModifier {
    let maxWidth: CGFloat
    let sideRoom: CGFloat
    let outerWidth: CGFloat?

    /// What a scroller can take from the scroll view's width.
    static var scrollerRoom: CGFloat {
        #if os(macOS)
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        #else
        0
        #endif
    }

    /// The column's width in a scroll view `outerWidth` wide.
    static func width(maxWidth: CGFloat, sideRoom: CGFloat, outerWidth: CGFloat) -> CGFloat {
        max(0, min(maxWidth, outerWidth - 2 * sideRoom - scrollerRoom))
    }

    func body(content: Content) -> some View {
        if let outerWidth {
            let width = Self.width(maxWidth: maxWidth, sideRoom: sideRoom, outerWidth: outerWidth)
            content
                .frame(width: width)
                .padding(.leading, max(0, (outerWidth - width) / 2))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Before the scroll view's width is known: centered in what it offers.
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, sideRoom)
        }
    }
}

/// The chat's scroll position, shared by what moves it: a prompt sent from the chat
/// brings it to its end (`promptScrolling`), and a fold that opens or closes keeps its
/// line where it was (`keepingPlace`).
///
/// The chat keeps its bottom as its content changes size (`defaultScrollAnchor`), so
/// it follows a streaming reply. A fold opening grew the content below its line, and
/// the chat kept its bottom: the line moved up by the height it opened to, and closing
/// it again meant finding the line first. Choosing the anchor per change did not work
/// (an anchor changed with the content came too late for it, and one read from the
/// scroll geometry stopped the chat following a reply, VM 2026-10-18); the fold
/// scrolls back to where the chat was instead.
@MainActor @Observable final class ChatScroll {
    var position = ScrollPosition(idType: String.self)
    /// The content's y at the top of the visible area (under the title bar), in
    /// `position`'s terms. Not observed: it changes on every frame of a scroll.
    @ObservationIgnored private(set) var shownY: CGFloat = 0

    /// Makes `change` (a fold opening or closing) and keeps the content on screen where
    /// it was, in the same update.
    func keepingPlace(_ change: () -> Void) {
        let y = shownY
        change()
        position.scrollTo(y: y)
    }

    /// The chat scrolled: `contentOffset` counts the top inset, a `ScrollPosition`
    /// point does not.
    nonisolated static func shownY(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }

    fileprivate func scrolled(to y: CGFloat) { shownY = y }
}

extension EnvironmentValues {
    /// The chat's scroll position, for the folds in it (`ChatScroll.keepingPlace`).
    @Entry var chatScroll: ChatScroll? = nil
    /// Whether the chat is the one on screen, for its composer. False for a warm chat
    /// kept built but hidden (`KeptChats`): its composer neither takes the keyboard nor
    /// attaches pastes.
    @Entry var chatIsShown = true
}

extension View {
    /// Binds the chat's scroll view to `scroll` (`ChatScroll`).
    func chatScrolling(_ scroll: ChatScroll) -> some View {
        modifier(ChatScrolling(scroll: scroll))
    }
}

private struct ChatScrolling: ViewModifier {
    @Bindable var scroll: ChatScroll

    func body(content: Content) -> some View {
        content
            .environment(\.chatScroll, scroll)
            .scrollPosition($scroll.position)
            .onScrollGeometryChange(for: CGFloat.self, of: { ChatScroll.shownY($0) }) { _, y in
                scroll.scrolled(to: y)
            }
    }
}

extension View {
    /// A kept chat: drawn and reachable only while shown (`KeptChats`). Hidden, it
    /// keeps the width it was last shown at, so resizing the window lays out only the
    /// chat on screen, and it reports no size, so it never widens the column.
    ///
    /// Nothing here changes the chat's environment: a change there updates every row's
    /// text view, which made a switch between kept chats cost a third of a rebuild (VM,
    /// 2026-10-18). The composer is told on its own (`ChatView.isShown`).
    func keptChat(isShown: Bool) -> some View {
        modifier(KeptChat(isShown: isShown))
    }
}

private struct KeptChat: ViewModifier {
    let isShown: Bool
    @State private var width: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(width: isShown ? nil : width)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
                if isShown { width = newWidth }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}
