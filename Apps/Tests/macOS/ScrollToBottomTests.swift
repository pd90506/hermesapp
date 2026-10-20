import AppKit
import HermesKit
import SwiftUI
import Testing

/// When the chat's scroll-to-bottom button shows (`ChatScroll.isAwayFromEnd`), in a scroll
/// view built like `ChatView`'s, a composer's inset under it: hidden at the end, shown
/// once scrolled up, hidden again back at the end.
@MainActor
@Suite(.serialized) struct ScrollToBottomTests {
    @MainActor final class Probe {
        var geometry: ScrollGeometry?
    }

    private struct Harness: View {
        let scroll: ChatScroll
        let probe: Probe
        static let rows = 40
        static let composerHeight: CGFloat = 150

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<Self.rows, id: \.self) { Text("Row \($0)").frame(height: 60) }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .chatScrolling(scroll)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { [probe] _, geometry in
                probe.geometry = geometry
            }
            .safeAreaInset(edge: .bottom) { Color.gray.frame(height: Self.composerHeight) }
        }
    }

    @Test func theButtonShowsOnlyAwayFromTheEnd() {
        let scroll = ChatScroll()
        let probe = Probe()
        let window = NSWindow(contentRect: .testArea(CGSize(width: 500, height: 600)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Harness(scroll: scroll, probe: probe))
        window.showInTestArea()
        defer { window.close() }
        func waitFor(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while !condition() {
                if Date() > deadline { return false }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return true
        }
        _ = waitFor { probe.geometry != nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(scroll.isAtEnd, "opens at its end: \(String(describing: probe.geometry))")
        #expect(!scroll.isAwayFromEnd, "no button at the end: \(String(describing: probe.geometry))")

        scroll.position.scrollTo(y: 0)
        #expect(waitFor { scroll.isAwayFromEnd }, "scrolled up, the button: \(String(describing: probe.geometry))")
        #expect(!scroll.isAtEnd)

        scroll.scrollToEnd(reduceMotion: true)
        #expect(waitFor { !scroll.isAwayFromEnd }, "back at the end, no button: \(String(describing: probe.geometry))")
        #expect(scroll.isAtEnd, "back at its end: \(String(describing: probe.geometry))")
    }
}
