import AppKit
import SwiftUI
import Testing

/// The composer's placeholder ("Message Hermes") shows only while the field shows
/// nothing. An input method's marked text (Pinyin before a candidate is picked) is
/// something, though the draft may not hold it: AppKit reports some marked-text edits
/// to the delegate and not others.
@MainActor
@Suite struct ComposerPlaceholderTests {
    private final class Box {
        var text = ""
        var composing = false
        var reports: [Bool] = []
        var height: CGFloat = 0

        var showsPlaceholder: Bool { ComposerTextView.showsPlaceholder(draft: text, composing: composing) }
    }

    private func makeView(_ box: Box) -> ComposerTextView.Coordinator {
        let view = ComposerTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            contentHeight: Binding(get: { box.height }, set: { box.height = $0 }),
            maxHeight: 170, focusRequest: 0, onSubmit: {}, onAttach: { _ in }, onProviders: { _ in },
            onComposingChange: { box.composing = $0; box.reports.append($0) })
        let coordinator = ComposerTextView.Coordinator(view)
        let scrollView = ComposerTextView.makeScrollView(coordinator: coordinator, text: "")
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        scrollView.tile()
        return coordinator
    }

    private func compose(_ text: String, in textView: NSTextView) {
        textView.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Panda's report: Pinyin `dddd` drawn over the grey placeholder.
    @Test func markedTextHidesThePlaceholder() throws {
        let box = Box()
        let coordinator = makeView(box)
        let textView = try #require(coordinator.textView)
        #expect(box.showsPlaceholder)

        compose("dddd", in: textView)
        #expect(textView.hasMarkedText())
        #expect(box.text.isEmpty, "the draft has not seen the marked letters")
        #expect(!box.showsPlaceholder, "the placeholder shows under the marked text")

        compose("ddddd", in: textView)
        #expect(!box.showsPlaceholder)
        #expect(box.reports == [true], "reported once per change")
    }

    /// A cancelled composition (Escape) leaves the field empty: the placeholder returns.
    @Test func aCancelledCompositionBringsThePlaceholderBack() throws {
        let box = Box()
        let coordinator = makeView(box)
        let textView = try #require(coordinator.textView)
        compose("ni", in: textView)
        #expect(!box.showsPlaceholder)

        compose("", in: textView)
        textView.unmarkText()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(textView.string.isEmpty)
        #expect(box.showsPlaceholder)
    }

    /// Picking a candidate ends the composition; the committed text keeps it hidden.
    @Test func aCommittedCandidateKeepsThePlaceholderHidden() throws {
        let box = Box()
        let coordinator = makeView(box)
        let textView = try #require(coordinator.textView)
        compose("nihao", in: textView)
        textView.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(!textView.hasMarkedText())
        #expect(!box.composing)
        #expect(box.text == "你好")
        #expect(!box.showsPlaceholder)
    }
}
