import AppKit
import SwiftUI
import Testing

/// Exercises AppKit's actual text command routing without a gateway or timers.
@MainActor
@Suite struct ComposerSlashKeyboardTests {
    private final class State {
        var open = true
        var selected = 0
        var accepted = false
        /// What the composer says to Return (`acceptSlashSuggestionFromKey`): false sends instead.
        var returnAccepts = true
        var submits = 0
    }

    private func makeView(_ state: State) -> (ComposerTextView.Coordinator, ComposerNSTextView) {
        let view = ComposerTextView(
            text: .constant("/"), contentHeight: .constant(28), maxHeight: 170, focusRequest: 0,
            onSubmit: { state.submits += 1 }, onImages: { _ in }, onImageProviders: { _ in },
            onSlashKey: { key in
                guard state.open else { return false }
                switch key {
                case .up: state.selected -= 1
                case .down: state.selected += 1
                case .tab: state.accepted = true; state.open = false
                case .accept:
                    guard state.returnAccepts else { return false }
                    state.accepted = true; state.open = false
                case .escape: state.open = false
                }
                return true
            })
        let coordinator = ComposerTextView.Coordinator(view)
        let scroll = ComposerTextView.makeScrollView(coordinator: coordinator, text: "/")
        return (coordinator, scroll.documentView as! ComposerNSTextView)
    }

    @Test func navigateAcceptEscapeAndSendWhenClosed() {
        let state = State()
        let (coordinator, field) = makeView(state)
        #expect(coordinator.textView(field, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(coordinator.textView(field, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(state.selected == 0)
        #expect(coordinator.textView(field, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(state.accepted)
        #expect(coordinator.textView(field, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(state.submits == 1)
        state.open = true
        #expect(coordinator.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!state.open)
        #expect(field.string == "/")
    }

    /// Return the composer declines (a free-text argument, nothing matching what was
    /// typed) falls through to sending, with the list still open.
    @Test func declinedReturnSends() {
        let state = State()
        state.returnAccepts = false
        let (coordinator, field) = makeView(state)
        #expect(coordinator.textView(field, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(state.submits == 1)
        #expect(!state.accepted)
    }

    @Test func keyMappingKeepsShiftReturnANewline() {
        typealias C = ComposerTextView.Coordinator
        #expect(C.slashKey(for: #selector(NSResponder.insertNewline(_:)), flags: []) == .accept)
        #expect(C.slashKey(for: #selector(NSResponder.insertNewline(_:)), flags: .shift) == nil)
        #expect(C.slashKey(for: #selector(NSResponder.insertNewline(_:)), flags: .option) == nil)
        #expect(C.slashKey(for: #selector(NSResponder.insertTab(_:)), flags: []) == .tab)
        #expect(C.slashKey(for: #selector(NSResponder.moveDown(_:)), flags: .command) == nil)
        #expect(C.slashKey(for: #selector(NSResponder.cancelOperation(_:)), flags: []) == .escape)
        #expect(C.slashKey(for: #selector(NSResponder.insertLineBreak(_:)), flags: []) == nil)
    }

    @Test func markedTextOwnsNavigationCommitAndCancel() {
        let state = State()
        let (coordinator, field) = makeView(state)
        field.setMarkedText(NSMutableAttributedString(string: "ni"), selectedRange: NSRange(location: 2, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.hasMarkedText())
        for selector in [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
                         #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!coordinator.textView(field, doCommandBy: selector))
        }
        #expect(state.open)
        #expect(state.selected == 0)
        #expect(state.submits == 0)
    }
}
