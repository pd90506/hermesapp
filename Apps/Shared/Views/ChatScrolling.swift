import SwiftUI

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

/// Which edge of the chat stays put when its content changes size.
///
/// - Scrolled to the end, the bottom: a streaming reply grows and the chat follows it.
/// - Anywhere else, the top: the rows on screen stay where they are, so a reply
///   streaming below them doesn't push them up while the user reads.
/// - While an older page is read, the bottom: the page lands above the rows on screen.
/// - Just after a fold opens or closes (`hold`), the top, even at the end: the fold's
///   line stays under the pointer and its content opens below it. Anchored at the
///   bottom, the line moved up by the height it opened to, and closing it again meant
///   finding the line first.
@MainActor @Observable final class ChatScrollAnchor {
    /// The chat is scrolled to its end, within `endTolerance`.
    var isAtEnd = true
    private(set) var isHeld = false
    @ObservationIgnored private var holds = 0

    nonisolated static let endTolerance: CGFloat = 8

    func anchor(readingOlderPage: Bool) -> UnitPoint {
        if isHeld { return .top }
        return isAtEnd || readingOlderPage ? .bottom : .top
    }

    /// Keeps the rows on screen where they are while a fold opens or closes: anchors
    /// the top, then makes `change` a moment later. Made in the same update as the
    /// change, the new anchor came too late for it: the chat still kept its bottom
    /// (measured in the VM, 2026-10-18).
    func hold(then change: @escaping @MainActor @Sendable () -> Void) {
        holds += 1
        let hold = holds
        isHeld = true
        // Dispatched rather than awaited: a window test's run loop runs these, and a
        // task's sleep never resumed there (VM, 2026-10-18).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.anchorLead) {
            MainActor.assumeIsolated { change() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.anchorLead + Self.holdDuration) {
            MainActor.assumeIsolated {
                if self.holds == hold { self.isHeld = false }
            }
        }
    }

    /// About a frame: the anchor reaches the scroll view before the content changes.
    static let anchorLead: TimeInterval = 0.02
    /// Long enough for a fold's animation (`snappy`, 0.2 s) to finish.
    static let holdDuration: TimeInterval = 0.6

    /// Follows a scroll (`ChatScrollAnchoring`). Only a move decides whether the chat
    /// is at its end: when the content grows, its new size is reported before the
    /// anchor has moved the view to the new end, and reading "not at the end" there
    /// stopped the chat following a reply (VM, 2026-10-18). While a fold holds the
    /// top, a growth is real: what opened below the screen is not at the end.
    func scrolled(from old: ChatScrollPlace, to new: ChatScrollPlace) {
        guard isHeld || new.offset != old.offset || new.container != old.container else { return }
        isAtEnd = new.isAtEnd
    }

    /// Whether `geometry` shows the end of the content (the composer's inset aside).
    nonisolated static func isAtEnd(_ geometry: ScrollGeometry) -> Bool {
        let shownBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
        return shownBottom >= geometry.contentSize.height - endTolerance
    }
}

extension EnvironmentValues {
    /// The chat's scroll anchor, for the folds in it to hold (`ChatScrollAnchor.hold(then:)`).
    @Entry var chatScrollAnchor: ChatScrollAnchor? = nil
}

extension View {
    /// The chat's scroll anchors (`ChatScrollAnchor`), on its scroll view. The chat
    /// opens at its end.
    func chatScrollAnchoring(_ anchor: ChatScrollAnchor, readingOlderPage: Bool = false) -> some View {
        modifier(ChatScrollAnchoring(anchor: anchor, readingOlderPage: readingOlderPage))
    }
}

/// A modifier of its own, so a change of anchor updates the anchors only and not the
/// whole transcript.
private struct ChatScrollAnchoring: ViewModifier {
    let anchor: ChatScrollAnchor
    let readingOlderPage: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.chatScrollAnchor, anchor)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(anchor.anchor(readingOlderPage: readingOlderPage), for: .sizeChanges)
            .onScrollGeometryChange(for: ChatScrollPlace.self, of: { ChatScrollPlace($0) }) {
                anchor.scrolled(from: $0, to: $1)
            }
    }
}

/// Where the chat is scrolled to, as `ChatScrollAnchor.scrolled(from:to:)` reads it.
struct ChatScrollPlace: Equatable, Sendable {
    var offset: CGFloat
    var container: CGFloat
    var isAtEnd: Bool

    nonisolated init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        container = geometry.containerSize.height
        isAtEnd = ChatScrollAnchor.isAtEnd(geometry)
    }
}
