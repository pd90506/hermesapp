import HermesKit
import SwiftUI

@MainActor
final class ComposerInputHandle {
    /// Installed by the native editor. Weak captures keep kept-chat editors releasable.
    var prepareSubmission: (() -> Void)?
}

/// The composer's multi-line text area. It reports the height its text needs
/// (`contentHeight`); the caller caps it at `maxHeight`, and the view scrolls past
/// the cap. Below the cap no scroller is ever shown, not even for one frame.
///
/// Keys:
/// - macOS: Return sends, Shift-Return or Option-Return inserts a newline (as in
///   Hermes Desktop). Return while an input method has marked text (e.g. picking a
///   Chinese candidate) goes to the input method and never sends.
/// - iOS: Return inserts a newline; the Send button (or Command-Return on a hardware
///   keyboard) sends, as in Messages.
///
/// Pasting an image or a copied file attaches it instead of inserting anything
/// (`ClipboardPolicy` decides); dropping files onto the text attaches them. On macOS,
/// Command-V with an image or file on the clipboard attaches it whenever the chat's
/// window is focused and no other editable text has the keyboard.
struct ComposerTextView {
    /// What UI tests find the composer by: the replies are text views too.
    static let accessibilityIdentifier = "composer"
    /// `accept` is plain Return; Shift-Return still inserts a newline.
    typealias SlashKey = SlashListKey
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    /// The tallest the text area gets; past it, the text scrolls.
    var maxHeight: CGFloat
    /// Bumped by the caller to move keyboard focus here.
    var focusRequest: Int
    var onSubmit: () -> Void
    var onAttach: ([AttachmentSource]) -> Void
    /// iOS pastes: the pasteboard's image and file item providers.
    var onProviders: ([NSItemProvider]) -> Void
    /// Whether an input method's marked text shows now (e.g. Pinyin before a candidate
    /// is picked). The draft may not hold it: AppKit reports some marked-text edits and
    /// not others, and a draft changed meanwhile waits for the composition (`DraftMerge`).
    var onComposingChange: (Bool) -> Void = { _ in }
    /// Called only when AppKit has no marked text. Returning true consumes the key.
    var onSlashKey: (SlashKey) -> Bool = { _ in false }
    /// iOS: the text view took or gave up the keyboard.
    var onFocusChange: (Bool) -> Void = { _ in }
    var inputHandle: ComposerInputHandle? = nil

    static let verticalInset: CGFloat = 4

    /// The placeholder shows only while the field shows nothing: no draft and no marked
    /// text. A cancelled composition that leaves the field empty brings it back.
    static func showsPlaceholder(draft: String, composing: Bool) -> Bool {
        draft.isEmpty && !composing
    }
}

#if os(macOS)
import AppKit

extension ComposerTextView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator, text: text)
    }

    /// The scroll view and its text view, wired to `coordinator` (separate from
    /// `makeNSView` so tests can build it without SwiftUI).
    @MainActor
    static func makeScrollView(coordinator: Coordinator, text: String) -> ComposerScrollView {
        // TextKit 1 from the start (`measure` and `UniformLines` read the layout manager).
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.attachUniformLines()
        textView.delegate = coordinator
        textView.setAccessibilityIdentifier(ComposerTextView.accessibilityIdentifier)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // No work that starts when typing pauses: inline predictions, completion
        // candidates, grammar checking and autocorrection. The first key after a pause was
        // slow, and the lines moved while Chinese was typed (the user, 2026-10-19).
        // Desktop's text area (Chromium) has none of them either.
        textView.inlinePredictionType = .no
        textView.isAutomaticTextCompletionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.setAccessibilityLabel("Message")
        textView.string = text

        let scrollView = ComposerScrollView()
        scrollView.contentView = ComposerClipView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Off until the text is taller than `maxHeight` (`Coordinator.measure`). An
        // auto-hiding scroller that is merely enabled flashes on every new line: the
        // text view grows a frame before the SwiftUI frame catches up.
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        coordinator.known = text
        coordinator.bind(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        coordinator.bind(textView)
        coordinator.showDraft()
        // The content size (Settings ▸ Appearance); 13 pt, the body style, by default.
        let size = context.environment.textSizes.content
        if textView.font?.pointSize != size {
            textView.font = .systemFont(ofSize: size)
            coordinator.measure(during: .viewUpdate)
        }
        // A kept chat shown again takes the keyboard back; one hidden gives it up
        // (`KeptChats`), so typing never goes to a chat that is not on screen.
        let isShown = context.environment.chatIsShown
        textView.acceptsDrops = isShown
        if coordinator.focusRequest != focusRequest || coordinator.isShown != isShown {
            let focus = isShown && (coordinator.focusRequest != focusRequest || !coordinator.isShown)
            coordinator.focusRequest = focusRequest
            coordinator.isShown = isShown
            if focus {
                DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
            } else if !isShown, let window = textView.window, window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopPasteMonitor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        weak var scrollView: NSScrollView?
        var focusRequest: Int
        /// The chat is on screen (`chatIsShown`): a hidden one attaches no pastes.
        var isShown = true
        private var pasteMonitor: Any?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest - 1  // focus on first appearance
        }

        func bind(_ textView: ComposerNSTextView) {
            textView.onAttach = { [weak self] in self?.parent.onAttach($0) }
            textView.onResize = { [weak self] in self?.measure(during: .layout) }
            textView.onWindow = { [weak self] window in
                if window == nil { self?.stopPasteMonitor() } else { self?.startPasteMonitor() }
            }
            // Marked text that wraps onto a new line needs the height now: AppKit doesn't
            // report every marked-text edit as a text change (as Desktop's field, which
            // grows with the composition).
            textView.onMarkedTextChange = { [weak self] in
                self?.reportComposing()
                self?.measure(during: .edit)
            }
        }

        /// Whether marked text showed when last reported.
        private var composing = false

        /// Tells the composer whether marked text shows (only on a change).
        func reportComposing() {
            guard let textView, textView.hasMarkedText() != composing else { return }
            composing.toggle()
            parent.onComposingChange(composing)
        }

        /// The draft as this view last left it: shown, or reported after an edit.
        var known = ""
        /// A draft changed outside the view while an input method composed, and the
        /// draft it replaced: shown once the composition ends (`DraftMerge`).
        private var held: (base: String, draft: String)?

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if let held {
                // The draft keeps the app's text while the input method composes.
                guard !textView.hasMarkedText() else { return measure(during: .edit) }
                self.held = nil
                let merged = DraftMerge.merge(base: held.base, theirs: held.draft, mine: textView.string)
                show(merged.text, caret: merged.caret)
            }
            known = textView.string
            parent.text = known
            measure(during: .edit)
        }

        /// Shows the draft when it changed outside the text view: cleared after a send,
        /// or a failed prompt's text given back (`ChatSession`). An input method's
        /// composition is never touched (committing it in code turned the letters into
        /// Latin, and its own edit report overwrote the draft during the SwiftUI
        /// update): the change waits for the composition to end. Whether the draft
        /// saw the marked letters doesn't matter (AppKit reports some marked-text
        /// edits and not others), as the change is told by the draft, not the view.
        func showDraft() {
            let draft = parent.text
            guard let textView, draft != known else { return }
            if textView.hasMarkedText() {
                held = (held?.base ?? known, draft)
            } else {
                held = nil
                show(draft, caret: (draft as NSString).length)
                measure(during: .viewUpdate)
            }
            known = draft
        }

        /// Text set in code. Undo steps recorded before it point into the old text,
        /// so they are dropped.
        private func show(_ text: String, caret: Int) {
            guard let textView else { return }
            textView.string = text
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            undo.removeAllActions()
        }

        /// The composer's own undo history (AppKit registers typing with an internal
        /// target, so it can only be cleared as a whole; the window's is shared).
        private let undo = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Let the input method own all navigation, commit and cancel keys.
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if let key = Self.slashKey(for: selector, flags: flags), parent.onSlashKey(key) { return true }
            guard selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertLineBreak(_:))
            else { return false }
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        /// The slash-list key a text command is, if any: plain arrows, Tab, Return
        /// and Escape. Shift-Return stays a newline; other modifiers keep their meaning.
        static func slashKey(for selector: Selector, flags: NSEvent.ModifierFlags) -> SlashKey? {
            guard flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return .up
            case #selector(NSResponder.moveDown(_:)): return .down
            case #selector(NSResponder.insertTab(_:)): return .tab
            case #selector(NSResponder.insertNewline(_:)): return flags.contains(.shift) ? nil : .accept
            case #selector(NSResponder.cancelOperation(_:)): return .escape
            default: return nil
            }
        }

        enum Moment {
            /// The user typed or pasted: outside any SwiftUI update.
            case edit
            /// Inside a SwiftUI update or an AppKit layout pass.
            case viewUpdate, layout
        }

        /// The height the text needs at the current width. The scroller is decided
        /// first, so a line that still fits never shows one. After an edit the height
        /// goes to SwiftUI at once, so the frame grows in the same pass as the text;
        /// during a view update or layout it is deferred, as SwiftUI requires.
        func measure(during moment: Moment) {
            guard let textView, let container = textView.textContainer,
                let layoutManager = textView.layoutManager
            else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .preferredFont(forTextStyle: .body))
            let used = max(layoutManager.usedRect(for: container).height, lineHeight)
            let height = ceil(used + 2 * ComposerTextView.verticalInset)
            let overflows = height > parent.maxHeight + 0.5
            if scrollView?.hasVerticalScroller != overflows { scrollView?.hasVerticalScroller = overflows }
            (scrollView?.contentView as? ComposerClipView)?.holdsTop = !overflows
            guard abs(parent.contentHeight - height) > 0.5 else { return }
            if moment == .edit {
                parent.contentHeight = height
            } else {
                let binding = parent.$contentHeight
                DispatchQueue.main.async { binding.wrappedValue = height }
            }
        }

        // MARK: Command-V anywhere in the chat window

        /// Command-V with an image on the clipboard attaches it even when the
        /// keyboard is elsewhere in this window (the transcript, the toolbar), as in
        /// Desktop. Editable text that has the keyboard keeps its own paste.
        private func startPasteMonitor() {
            guard pasteMonitor == nil else { return }
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handlesPaste(event) else { return event }
                return nil
            }
        }

        func stopPasteMonitor() {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }

        private func handlesPaste(_ event: NSEvent) -> Bool {
            guard isShown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "v",
                let textView, let window = textView.window, event.window === window
            else { return false }
            if let editing = window.firstResponder as? NSTextView, editing.isEditable { return false }
            let images = ImageLoader.sources(from: textView.pasteboard)
            guard !images.isEmpty else { return false }
            window.makeFirstResponder(textView)
            parent.onAttach(images)
            return true
        }
    }
}

/// Keeps the text in place while it fits. Typing Chinese moved the lines above up and
/// down (the user's report, 2026-10-19; not reproduced in the VM). One way it can: an
/// input method's edits scroll the text view to its marked text, and while the text view
/// is taller than the SwiftUI frame (a line being added, the frame not grown yet) that
/// scrolls the clip by a few points, until the frame's update scrolls it back. Below
/// `maxHeight` there is nothing to scroll to, so the clip stays at the top; past it, it
/// scrolls as usual.
final class ComposerClipView: NSClipView {
    var holdsTop = true

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        if holdsTop { bounds.origin.y = 0 }
        return bounds
    }
}

/// Every line of the composer the font's height, on the font's baseline, whatever its
/// glyphs: a line whose Chinese fell back to another font, or that shows an input
/// method's marked text, is as tall as one of Latin letters, so the lines above it don't
/// move while it is composed and committed.
///
/// And no line starts with a space. TextKit breaks Chinese after any character, so
/// "E把 prompt" could wrap between 把 and the space, and the next line began a space to
/// the right of the others (the user's report, 2026-10-21). Unicode line breaking
/// (UAX #14, LB7), which Desktop's Chromium field follows, never breaks before a space.
@MainActor
final class UniformLines: NSObject, @preconcurrency NSLayoutManagerDelegate {
    weak var textView: NSTextView?

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard let string = layoutManager.textStorage?.string as NSString?, charIndex < string.length else { return true }
        return !Self.isSpace(string.character(at: charIndex))
    }

    /// Spaces and tabs (U+0020, U+0009, U+00A0 and the other `Zs` spaces), not newlines.
    nonisolated static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "\t" || scalar.properties.generalCategory == .spaceSeparator
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let font = textView?.font else { return false }
        let height = layoutManager.defaultLineHeight(for: font)
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = layoutManager.defaultBaselineOffset(for: font)
        return true
    }
}

/// Keeps the text view exactly as wide as the visible area, whatever size
/// SwiftUI first creates the scroll view at.
final class ComposerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let documentView, documentView.frame.width != contentSize.width else { return }
        documentView.setFrameSize(NSSize(width: contentSize.width, height: documentView.frame.height))
    }
}

/// `NSTextView` that attaches pasted or dropped images and files instead of inserting them.
final class ComposerNSTextView: NSTextView {
    var onAttach: (([AttachmentSource]) -> Void)?
    var onResize: (() -> Void)?
    /// Joined (or left, `nil`) a window.
    var onWindow: ((NSWindow?) -> Void)?
    /// Marked text may have appeared, changed or gone.
    var onMarkedTextChange: (() -> Void)?
    /// The clipboard (tests use their own).
    var pasteboard: NSPasteboard = .general
    /// Holds every line at the font's height (`UniformLines`); the layout manager keeps
    /// its delegate weakly.
    private let uniformLines = UniformLines()

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        attachUniformLines()
    }

    func attachUniformLines() {
        guard let layoutManager, layoutManager.delegate !== uniformLines else { return }
        uniformLines.textView = self
        layoutManager.delegate = uniformLines
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?()
    }

    /// Also after a candidate is committed (`insertText` replaces the marked text).
    override func didChangeText() {
        super.didChangeText()
        onMarkedTextChange?()
    }

    override func paste(_ sender: Any?) {
        let images = ImageLoader.sources(from: pasteboard)
        if images.isEmpty { super.paste(sender) } else { onAttach?(images) }
    }

    /// A plain-text view enables Paste only for text it can read, so with just an
    /// image on the clipboard (a screenshot, Preview's Copy) Command-V never reached
    /// `paste(_:)`. Enable it for images too. Only the pasteboard's types are read
    /// here, never its contents: validation is not a paste.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return canPaste(from: pasteboard) }
        return super.validateUserInterfaceItem(item)
    }

    /// AppKit's own rule (a type this text view can read: `preferredPasteboardType`,
    /// which is nil for PNG or TIFF alone), widened to images.
    func canPaste(from board: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        return Self.mayHoldImages(board) || preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: nil) != nil
    }

    static func mayHoldImages(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        return !types.isDisjoint(with: ClipboardPolicy.imageDataTypes) || types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
    }

    /// Whether drops land here: not in a kept chat that is hidden (`KeptChats`). It lies
    /// where the chat on screen is, and AppKit picks a drop's view by frame and drag
    /// types, not by SwiftUI's opacity or hit testing, so a hidden chat's composer took
    /// files dropped on the one shown (the user's report, 2026-10-30: with several chats
    /// open, a file from the Dock's Downloads stack never showed up).
    var acceptsDrops = true {
        didSet { if acceptsDrops != oldValue { updateDragTypeRegistration() } }
    }

    override func updateDragTypeRegistration() {
        if acceptsDrops { super.updateDragTypeRegistration() } else { unregisterDraggedTypes() }
    }

    /// Whether the current drag carries images, decided once per drag (the
    /// pasteboard's contents don't change while it moves).
    private var dragCarriesImages: Bool?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let images = !ImageLoader.sources(from: sender.draggingPasteboard).isEmpty
        dragCarriesImages = images
        return images ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragCarriesImages == true ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragCarriesImages = nil
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dragCarriesImages = nil }
        let images = ImageLoader.sources(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        onAttach?(images)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onResize?() }
    }
}

#else
import UIKit
import UniformTypeIdentifiers

extension ComposerTextView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.accessibilityIdentifier = ComposerTextView.accessibilityIdentifier
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        // Shown only once the text is taller than the cap (`Coordinator.measure`).
        textView.showsVerticalScrollIndicator = false
        textView.accessibilityLabel = "Message"
        textView.text = text
        context.coordinator.known = text
        // Image drops go to the composer's own drop target (it attaches them);
        // the text view's drop interaction would only insert text.
        textView.interactions.removeAll { $0 is UIDropInteraction }
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.bind(textView)
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.bind(textView)
        coordinator.showDraft(in: textView)
        // The content size (Settings ▸ Appearance), still scaled by Dynamic Type.
        let size = context.environment.textSizes.content
        if coordinator.contentSize != size {
            coordinator.contentSize = size
            textView.font = size == TextSizes.defaults.content
                ? .preferredFont(forTextStyle: .body)
                : UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size))
            coordinator.measure(textView, deferred: true)
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            // Only on explicit requests: popping the keyboard on every chat open is intrusive on a phone.
            if coordinator.hasAppeared { DispatchQueue.main.async { textView.becomeFirstResponder() } }
        }
        // A kept chat that is hidden (`KeptChats`) gives up the keyboard.
        if !context.environment.chatIsShown, textView.isFirstResponder { textView.resignFirstResponder() }
        coordinator.hasAppeared = true
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var focusRequest: Int
        var hasAppeared = false
        /// The content size the font was last set for.
        var contentSize: CGFloat?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
        }

        func bind(_ textView: ComposerUITextView) {
            parent.inputHandle?.prepareSubmission = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.prepareSubmission(in: textView)
            }
            textView.onProviders = { [weak self] in self?.parent.onProviders($0) }
            textView.onLayout = { [weak self, weak textView] in
                if let textView { self?.measure(textView, deferred: true) }
            }
            // Marked text that wraps grows the field at once, as on macOS.
            textView.onMarkedTextChange = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.reportComposing(textView)
                if !self.isPreparingSubmission { self.measure(textView, deferred: false) }
            }
        }

        /// Whether marked text showed when last reported (as on macOS).
        private var composing = false

        func reportComposing(_ textView: UITextView) {
            guard !isPreparingSubmission else { return }
            let now = textView.markedTextRange.map { !$0.isEmpty } ?? false
            guard now != composing else { return }
            composing = now
            parent.onComposingChange(now)
        }

        /// The draft as this view last left it, and a draft changed outside it while
        /// an input method composed: as on macOS (`showDraft`).
        var known = ""
        private var held: (base: String, draft: String)?

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isPreparingSubmission else { return }
            reportComposing(textView)
            if let held {
                guard textView.markedTextRange == nil else { return measure(textView, deferred: false) }
                self.held = nil
                let merged = DraftMerge.merge(base: held.base, theirs: held.draft, mine: textView.text)
                show(merged.text, caret: merged.caret, in: textView)
            }
            known = textView.text
            parent.text = known
            measure(textView, deferred: false)
        }

        private var isPreparingSubmission = false

        /// Send is an explicit end to composition. Preserve exactly what is visible,
        /// rather than letting unmarkText select a different candidate. Finish this
        /// synchronously before ChatComposer snapshots/clears its draft; otherwise
        /// showDraft would hold that clear behind the still-active input method.
        func prepareSubmission(in textView: UITextView) {
            var visible = textView.text ?? ""
            if let held {
                visible = DraftMerge.merge(base: held.base, theirs: held.draft, mine: visible).text
            }
            isPreparingSubmission = true
            held = nil
            textView.unmarkText()
            show(visible, caret: (visible as NSString).length, in: textView)
            known = visible
            parent.text = visible
            isPreparingSubmission = false
            reportComposing(textView)
            measure(textView, deferred: false)
        }

        /// Shows the draft when it changed outside the text view; a composition is
        /// left to the input method, and the change waits for it to end.
        func showDraft(in textView: UITextView) {
            let draft = parent.text
            guard draft != known else { return }
            if textView.markedTextRange != nil {
                held = (held?.base ?? known, draft)
            } else {
                held = nil
                show(draft, caret: (draft as NSString).length, in: textView)
                measure(textView, deferred: true)
            }
            known = draft
        }

        /// Text set in code; undo steps recorded before it point into the old text.
        private func show(_ text: String, caret: Int, in textView: UITextView) {
            textView.text = text
            textView.selectedRange = NSRange(location: caret, length: 0)
            textView.undoManager?.removeAllActions()
        }

        func measure(_ textView: UITextView, deferred: Bool) {
            let width = textView.bounds.width
            guard width > 0 else { return }
            let height = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            textView.showsVerticalScrollIndicator = height > parent.maxHeight + 0.5
            guard abs(parent.contentHeight - height) > 0.5 else { return }
            if deferred {
                let binding = parent.$contentHeight
                DispatchQueue.main.async { binding.wrappedValue = height }
            } else {
                parent.contentHeight = height
            }
        }
    }
}

/// `UITextView` that attaches pasted images and files instead of inserting them.
final class ComposerUITextView: UITextView {
    var onProviders: (([NSItemProvider]) -> Void)?
    var onLayout: (() -> Void)?
    /// Marked text may have appeared, changed or gone.
    var onMarkedTextChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        onMarkedTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Metadata only (`hasImages`): reading the contents here would raise the
        // "Allow Paste" prompt each time the edit menu is validated. The contents
        // are read in `paste(_:)`, after the user picked Paste.
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages || Self.mayHoldFiles { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let providers = ImageLoader.pastedProviders()
        if providers.isEmpty { super.paste(sender) } else { onProviders?(providers) }
    }

    /// The pasteboard's types (metadata, no paste prompt) include a file's contents.
    private static var mayHoldFiles: Bool {
        UIPasteboard.general.types.contains { UTType($0).map(ImageLoader.isFileContent) ?? false }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onLayout?()
        }
    }
}
#endif
