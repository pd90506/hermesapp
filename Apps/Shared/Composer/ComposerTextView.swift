import SwiftUI

/// The composer's multi-line text area. It reports the height its text needs
/// (`contentHeight`); the caller caps it, and the view scrolls past the cap.
///
/// Keys:
/// - macOS: Return sends, Shift-Return or Option-Return inserts a newline (as in
///   Hermes Desktop). Return while an input method has marked text (e.g. picking a
///   Chinese candidate) goes to the input method and never sends.
/// - iOS: Return inserts a newline; the Send button (or Command-Return on a hardware
///   keyboard) sends, as in Messages.
///
/// Pasting an image (with no text on the pasteboard) attaches it instead of
/// inserting anything; dropping image files onto the text attaches them.
struct ComposerTextView {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    /// Bumped by the caller to move keyboard focus here.
    var focusRequest: Int
    var onSubmit: () -> Void
    var onImages: ([ImageSource]) -> Void
    /// iOS pastes: the pasteboard's image item providers.
    var onImageProviders: ([NSItemProvider]) -> Void

    static let verticalInset: CGFloat = 4
}

#if os(macOS)
import AppKit

extension ComposerTextView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
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
        textView.setAccessibilityLabel("Message")
        textView.string = text

        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.bind(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        coordinator.bind(textView)
        // Never overwrite text an input method is still composing.
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            coordinator.measure()
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var focusRequest: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest - 1  // focus on first appearance
        }

        func bind(_ textView: ComposerNSTextView) {
            textView.onImages = { [weak self] in self?.parent.onImages($0) }
            textView.onResize = { [weak self] in self?.measure() }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            measure()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertLineBreak(_:))
            else { return false }
            // Marked text: Return belongs to the input method.
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        /// The height the text needs, at the current width.
        func measure() {
            guard let textView, let container = textView.textContainer,
                let layoutManager = textView.layoutManager
            else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .preferredFont(forTextStyle: .body))
            let used = max(layoutManager.usedRect(for: container).height, lineHeight)
            let height = ceil(used + 2 * ComposerTextView.verticalInset)
            if abs(parent.contentHeight - height) > 0.5 {
                let binding = parent.$contentHeight
                DispatchQueue.main.async { binding.wrappedValue = height }
            }
        }
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

/// `NSTextView` that attaches pasted or dropped images instead of inserting them.
final class ComposerNSTextView: NSTextView {
    var onImages: (([ImageSource]) -> Void)?
    var onResize: (() -> Void)?

    override func paste(_ sender: Any?) {
        let images = ImageLoader.sources(from: NSPasteboard.general)
        if images.isEmpty { super.paste(sender) } else { onImages?(images) }
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
        onImages?(images)
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onResize?() }
    }
}

#else
import UIKit

extension ComposerTextView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.accessibilityLabel = "Message"
        textView.text = text
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
        if textView.text != text, textView.markedTextRange == nil {
            textView.text = text
            coordinator.measure(textView)
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            // Only on explicit requests: popping the keyboard on every chat open is intrusive on a phone.
            if coordinator.hasAppeared { DispatchQueue.main.async { textView.becomeFirstResponder() } }
        }
        coordinator.hasAppeared = true
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var focusRequest: Int
        var hasAppeared = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
        }

        func bind(_ textView: ComposerUITextView) {
            textView.onImageProviders = { [weak self] in self?.parent.onImageProviders($0) }
            textView.onLayout = { [weak self, weak textView] in
                if let textView { self?.measure(textView) }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            measure(textView)
        }

        func measure(_ textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0 else { return }
            let height = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if abs(parent.contentHeight - height) > 0.5 {
                let binding = parent.$contentHeight
                DispatchQueue.main.async { binding.wrappedValue = height }
            }
        }
    }
}

/// `UITextView` that attaches pasted images instead of inserting them.
final class ComposerUITextView: UITextView {
    var onImageProviders: (([NSItemProvider]) -> Void)?
    var onLayout: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Metadata only (`hasImages` / `hasStrings`): reading the contents here
        // would raise the "Allow Paste" prompt each time the edit menu is
        // validated. The contents are read in `paste(_:)`, after the user picked Paste.
        if action == #selector(paste(_:)) {
            let pasteboard = UIPasteboard.general
            if pasteboard.hasImages, !pasteboard.hasStrings { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let providers = ImageLoader.pastedImageProviders()
        if providers.isEmpty { super.paste(sender) } else { onImageProviders?(providers) }
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
