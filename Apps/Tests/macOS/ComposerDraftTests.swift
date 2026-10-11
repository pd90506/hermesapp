import AppKit
import SwiftUI
import Testing

/// The draft changed outside the text view (a failed prompt's text given back after a
/// rebuild) while an input method is composing: nothing is lost, and the composition
/// is left to the input method.
@MainActor
@Suite struct ComposerDraftWhileComposingTests {
    /// The draft, bound as SwiftUI binds it: during a view update, reading the binding
    /// gives the value from before the update, whatever was written meanwhile.
    private final class Box {
        var text = ""
        /// The value reads return during an update.
        var frozen: String?
        /// Every value the text view wrote.
        var writes: [String] = []
        var height: CGFloat = 0
        var submits = 0
    }

    private func makeView(_ box: Box) -> ComposerTextView.Coordinator {
        let view = ComposerTextView(
            text: Binding(get: { box.frozen ?? box.text }, set: { box.text = $0; box.writes.append($0) }),
            contentHeight: Binding(get: { box.height }, set: { box.height = $0 }),
            maxHeight: 170, focusRequest: 0, onSubmit: { box.submits += 1 }, onImages: { _ in },
            onImageProviders: { _ in })
        let coordinator = ComposerTextView.Coordinator(view)
        let scrollView = ComposerTextView.makeScrollView(coordinator: coordinator, text: "")
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        scrollView.tile()
        return coordinator
    }

    /// A SwiftUI update (`updateNSView`) with the binding frozen at its current value.
    private func render(_ box: Box, _ coordinator: ComposerTextView.Coordinator) {
        box.frozen = box.text
        coordinator.showDraft()
        box.frozen = nil
    }

    /// What the text view tells its delegate after an input method's edit.
    private func edited(_ box: Box, _ coordinator: ComposerTextView.Coordinator) {
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        render(box, coordinator)  // the draft changed: SwiftUI updates the view
    }

    private func compose(_ text: String, in textView: NSTextView) {
        textView.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func commit(_ text: String, in textView: NSTextView) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func textGivenBackWhileComposingIsNeverLost() throws {
        let box = Box()
        let coordinator = makeView(box)
        let textView = try #require(coordinator.textView)

        // Typing Pinyin: "ni" is marked, and the draft mirrors it.
        compose("ni", in: textView)
        edited(box, coordinator)
        #expect(box.text == "ni")

        // A rebuild gives a failed prompt's text back, ahead of the draft.
        box.writes = []
        box.text = "failed\nni"
        render(box, coordinator)
        render(box, coordinator)  // and whatever renders next, before any keystroke
        #expect(box.text == "failed\nni", "\(box.writes)")  // what Send would read now
        #expect(textView.string == "ni" && textView.hasMarkedText())  // the input method's still

        // The user goes on composing, then picks a candidate.
        compose("nih", in: textView)
        edited(box, coordinator)
        compose("nihao", in: textView)
        edited(box, coordinator)
        commit("你好", in: textView)
        edited(box, coordinator)

        #expect(box.writes.allSatisfy { $0.hasPrefix("failed\n") }, "\(box.writes)")
        #expect(box.text == "failed\n你好")  // nothing doubled, no Latin letters left
        #expect(textView.string == box.text)
        #expect(!textView.hasMarkedText())
    }

    /// The composition ends without a candidate (Escape): the given-back text stays.
    @Test func textGivenBackStaysWhenTheCompositionIsCancelled() throws {
        let box = Box()
        let coordinator = makeView(box)
        let textView = try #require(coordinator.textView)
        textView.string = "hi "
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        compose("ni", in: textView)
        edited(box, coordinator)
        #expect(box.text == "hi ni")

        box.text = "failed\nhi ni"
        render(box, coordinator)
        compose("", in: textView)
        textView.unmarkText()
        edited(box, coordinator)

        #expect(box.text == "failed\nhi ")
        #expect(textView.string == box.text)
    }

    /// A draft given back while nothing is composed is shown at once, and undo can
    /// no longer reach into the text it replaced.
    @Test func textGivenBackClearsTheUndoHistory() throws {
        let box = Box()
        let coordinator = makeView(box)
        let textView = try #require(coordinator.textView)
        let window = NSWindow(contentRect: .testArea(CGSize(width: 300, height: 100)), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = textView.enclosingScrollView
        let undo = try #require(textView.undoManager)
        commit("typed", in: textView)
        edited(box, coordinator)
        #expect(undo.canUndo)

        box.text = "failed"
        render(box, coordinator)

        #expect(textView.string == "failed")
        #expect(!undo.canUndo)
        #expect(window.undoManager !== undo)  // the composer's own: other fields keep theirs
    }

    // MARK: In a real SwiftUI view

    @Observable final class Draft {
        var text = ""
        var height: CGFloat = 0
    }

    struct Host: View {
        @Bindable var draft: Draft
        var body: some View {
            ComposerTextView(text: $draft.text, contentHeight: $draft.height, maxHeight: 170, focusRequest: 0,
                             onSubmit: {}, onImages: { _ in }, onImageProviders: { _ in })
                .frame(width: 300, height: 40)
        }
    }

    private func settle() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func textView(in view: NSView) -> ComposerNSTextView? {
        if let found = view as? ComposerNSTextView { return found }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    /// The same, hosted in `NSHostingView`: the draft is an `@Observable` model's,
    /// as in the app (`ComposerView`), and SwiftUI runs the updates. A `setMarkedText`
    /// from code reports no edit, though `insertText` and `unmarkText` do; typed
    /// marked text may be reported, so both are run.
    @Test(arguments: [false, true])
    func textGivenBackWhileComposingIsNeverLostInSwiftUI(markedTextReported: Bool) throws {
        let draft = Draft()
        let window = NSWindow(contentRect: .testArea(CGSize(width: 320, height: 60)), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(draft: draft))
        settle()
        let textView = try #require(textView(in: window.contentView!))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        settle()

        compose("ni", in: textView)
        if markedTextReported { textView.didChangeText() }
        settle()
        #expect(draft.text == (markedTextReported ? "ni" : ""))

        // `ChatComposer.restoreText`: ahead of a typed draft, or alone.
        let given = draft.text.isEmpty ? "failed" : "failed\n" + draft.text
        draft.text = given
        settle()
        #expect(draft.text == given)  // what Send would read now
        #expect(textView.hasMarkedText())
        settle()
        #expect(draft.text == given)

        commit("你", in: textView)
        settle()
        #expect(draft.text == (markedTextReported ? "failed\n你" : "failed你"))
        #expect(textView.string == draft.text)
        #expect(!textView.hasMarkedText())
    }

    /// The existing rule still holds: Return while composing goes to the input method.
    @Test func returnWhileComposingDoesNotSend() throws {
        let box = Box()
        let coordinator = makeView(box)
        let textView = try #require(coordinator.textView)
        compose("ni", in: textView)
        let handled = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(!handled)
        #expect(box.submits == 0)
    }
}
