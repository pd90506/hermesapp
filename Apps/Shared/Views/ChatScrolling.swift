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
    /// Whether the chat's end is on screen, for the prompt it is at (`PromptRail`).
    /// Observed, and set only when it changes.
    private(set) var isAtEnd = true
    /// Whether the chat is scrolled well up from its end, for the scroll-to-bottom
    /// button (`ScrollToBottomButton`). Observed, and set only when it changes.
    private(set) var isAwayFromEnd = false
    /// Whether the user is scrolling the chat (a wheel, a trackpad and its momentum).
    /// Observed, and set only when it changes.
    private(set) var isScrolling = false

    /// How far up from the end the button shows: Desktop's (use-stick-to-bottom's
    /// near-bottom band, 70 px), so a nudge or a reply's last lines don't bring it up.
    nonisolated static let awayFromEndDistance: CGFloat = 70

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

    /// Whether the content's bottom is on screen, within a few points: the bottom of the
    /// visible area (above the composer's inset) is at or past it.
    nonisolated static func isAtEnd(_ geometry: ScrollGeometry) -> Bool {
        shownBottom(geometry) >= geometry.contentSize.height - 8
    }

    /// The bottom of the visible area, in the content: the top of it (`shownY`) plus
    /// `containerSize`, which is already the part between the insets. At the end it is
    /// the content's height: on the Mac offset 2458 + container 442 = content 2900 (no
    /// top inset, a 158 pt composer under it); on iPhone offset 1397 + top inset 116 +
    /// container 304 = content 1817 (a 454 pt bar and keyboard under it; VM 2026-10-19).
    /// Taking the bottom inset off again left a chat at its end that much short of it.
    nonisolated static func shownBottom(_ geometry: ScrollGeometry) -> CGFloat {
        shownY(geometry) + geometry.containerSize.height
    }

    /// Whether the visible area's bottom is more than `awayFromEndDistance` above the
    /// content's bottom.
    nonisolated static func isAwayFromEnd(_ geometry: ScrollGeometry) -> Bool {
        shownBottom(geometry) < geometry.contentSize.height - awayFromEndDistance
    }

    /// The scroll-to-bottom button: down to the newest message, smoothly; at once with
    /// Reduce Motion.
    func scrollToEnd(reduceMotion: Bool = false) {
        withAnimation(reduceMotion ? nil : Motion.scrollToEnd) { position.scrollTo(edge: .bottom) }
    }

    fileprivate func scrolled(to y: CGFloat) { shownY = y }
    fileprivate func reachedEnd(_ atEnd: Bool) { isAtEnd = atEnd }
    fileprivate func leftEnd(_ away: Bool) { isAwayFromEnd = away }
    fileprivate func scrollPhase(_ phase: ScrollPhase) {
        let scrolling = phase == .interacting || phase == .decelerating
        if scrolling != isScrolling { isScrolling = scrolling }
    }
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
            .onScrollGeometryChange(for: Bool.self, of: { ChatScroll.isAtEnd($0) }) { _, atEnd in
                scroll.reachedEnd(atEnd)
            }
            .onScrollGeometryChange(for: Bool.self, of: { ChatScroll.isAwayFromEnd($0) }) { _, away in
                scroll.leftEnd(away)
            }
            .onScrollPhaseChange { _, phase in scroll.scrollPhase(phase) }
    }
}

extension View {
    /// The chat's rows take no pointer while the user scrolls them (Mac).
    ///
    /// Each frame of a scroll moved the rows under a still pointer, and AppKit and SwiftUI
    /// hit-tested every row again: the cursor's shape, and the hover of each row and
    /// button, about 15% of the main thread in a long chat (Instruments on the user's Mac,
    /// 2026-10-21). Browsers, and so Hermes Desktop, leave hover alone while scrolling
    /// too. The wheel goes to the scroll view all the same (`ScrollLatching`).
    func quietWhileScrolling(_ scroll: ChatScroll) -> some View {
        modifier(QuietWhileScrolling(scroll: scroll))
    }
}

private struct QuietWhileScrolling: ViewModifier {
    let scroll: ChatScroll

    func body(content: Content) -> some View {
        #if os(macOS)
        content.allowsHitTesting(!scroll.isScrolling)
        #else
        content
        #endif
    }
}

extension View {
    /// A kept chat on iPad: drawn and reachable only while shown (`KeptChats`; the Mac
    /// keeps each chat in its own hosting view, `KeptViews`). Hidden, it keeps the width
    /// it was last shown at, so resizing the window lays out only the chat on screen,
    /// and it reports no size, so it never widens the column.
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
            // On top of the hidden ones: drops go to the topmost target under the
            // pointer, whatever its opacity or hit testing, and a hidden chat's composer
            // took (or turned away) files dropped on the one shown (the user's report,
            // 2026-10-30, a file from the Dock's Downloads stack).
            .zIndex(isShown ? 1 : 0)
            .accessibilityHidden(!isShown)
    }
}
