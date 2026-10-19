import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

// AppKit behaviour of the composer's text view, with private NSPasteboards so the
// user's clipboard is never touched.

/// A pasteboard of its own, emptied.
@MainActor
private func pasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("hermes-test-\(UUID().uuidString)"))
    board.clearContents()
    return board
}

private let pngBytes: Data = {
    let image = NSImage(size: NSSize(width: 4, height: 3))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 3).fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}()

private let tiffBytes: Data = NSBitmapImageRep(data: pngBytes)!.tiffRepresentation!

@MainActor
private func filename(_ source: AttachmentSource) -> String {
    switch source {
    case .data(_, let filename): filename
    case .file(let url): url.lastPathComponent
    }
}

@MainActor
@Suite struct ComposerPasteTests {
    private let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

    /// ⌃⇧⌘4 to the clipboard puts only PNG data there. A plain-text view does not
    /// enable Paste for that, so Command-V never reached `paste(_:)`.
    @Test func commandVIsEnabledForAScreenshotAndAttachesIt() {
        let board = pasteboard()
        board.setData(pngBytes, forType: .png)
        let textView = ComposerNSTextView()
        textView.pasteboard = board
        var attached: [AttachmentSource] = []
        textView.onAttach = { attached = $0 }

        // AppKit alone would not: a plain-text view reads no image type.
        #expect(textView.preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: nil) == nil)
        #expect(textView.canPaste(from: board))
        #expect(textView.validateUserInterfaceItem(pasteItem))
        textView.paste(nil)
        #expect(attached.map(filename) == ["Pasted Image.png"])
        #expect(textView.string.isEmpty)
    }

    @Test func pasteStaysDisabledForAnEmptyClipboard() {
        let textView = ComposerNSTextView()
        #expect(!textView.canPaste(from: pasteboard()))
    }

    @Test func plainTextStillPastesAsText() {
        let board = pasteboard()
        board.setString("first line\nsecond line", forType: .string)
        let textView = ComposerNSTextView()
        textView.pasteboard = board
        var attached = false
        textView.onAttach = { _ in attached = true }

        #expect(textView.validateUserInterfaceItem(pasteItem))
        #expect(ImageLoader.sources(from: board).isEmpty)
        textView.paste(nil)  // reads `pasteboard`, so it inserts this board's text
        #expect(!attached)
    }
}

@MainActor
@Suite struct ClipboardSourcesTests {
    @Test func previewCopyIsAttached() {
        let board = pasteboard()
        board.setData(tiffBytes, forType: .tiff)
        #expect(ImageLoader.sources(from: board).map(filename) == ["Pasted Image.tiff"])
    }

    /// Safari's Copy Image: the picture, with its address as a URL and a string.
    @Test func browserCopyImageWithItsURLIsAttached() {
        let board = pasteboard()
        board.declareTypes([.tiff, .URL, .string], owner: nil)
        board.setData(tiffBytes, forType: .tiff)
        board.setString("https://example.com/cat.png", forType: .URL)
        board.setString("https://example.com/cat.png", forType: .string)
        #expect(ImageLoader.sources(from: board).map(filename) == ["Pasted Image.tiff"])
    }

    /// Chrome's Copy Image: PNG and an `<img>` tag.
    @Test func browserCopyImageWithHTMLIsAttached() {
        let board = pasteboard()
        board.declareTypes([.png, .html], owner: nil)
        board.setData(pngBytes, forType: .png)
        board.setString(#"<img src="https://example.com/cat.png">"#, forType: .html)
        #expect(ImageLoader.sources(from: board).map(filename) == ["Pasted Image.png"])
    }

    /// Finder's Copy of an image file: its URL, its name as a string, its icon as TIFF.
    @Test func finderCopyOfAnImageFileAttachesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-test-\(UUID().uuidString).png")
        try pngBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let board = pasteboard()
        board.writeObjects([url as NSURL])
        board.addTypes([.string, .tiff], owner: nil)
        board.setString(url.lastPathComponent, forType: .string)
        board.setData(tiffBytes, forType: .tiff)
        #expect(ImageLoader.sources(from: board).map(filename) == [url.lastPathComponent])
    }

    /// Finder's Copy of a PDF: the file is attached (as a file), never its icon.
    @Test func finderCopyOfAnotherFileAttachesTheFile() {
        let board = pasteboard()
        board.writeObjects([URL(fileURLWithPath: "/tmp/report.pdf") as NSURL])
        board.addTypes([.tiff], owner: nil)
        board.setData(tiffBytes, forType: .tiff)
        let sources = ImageLoader.sources(from: board)
        #expect(sources.map(filename) == ["report.pdf"])
        #expect(sources.map(\.isImage) == [false])
    }

    /// A spreadsheet range carries a picture of itself beside the text.
    @Test func aSpreadsheetRangeStaysText() {
        let board = pasteboard()
        board.declareTypes([.string, .rtf, .tiff], owner: nil)
        board.setString("name\tqty\napples\t3", forType: .string)
        board.setData(Data("{\\rtf1 x}".utf8), forType: .rtf)
        board.setData(tiffBytes, forType: .tiff)
        #expect(ImageLoader.sources(from: board).isEmpty)
    }
}

@MainActor
@Suite struct ComposerScrollerTests {
    private final class Box { var height: CGFloat = 0 }

    private func makeView(_ box: Box) -> (ComposerTextView.Coordinator, ComposerScrollView) {
        let view = ComposerTextView(
            text: .constant(""), contentHeight: Binding(get: { box.height }, set: { box.height = $0 }),
            maxHeight: 170, focusRequest: 0, onSubmit: {}, onAttach: { _ in }, onProviders: { _ in })
        let coordinator = ComposerTextView.Coordinator(view)
        let scrollView = ComposerTextView.makeScrollView(coordinator: coordinator, text: "")
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        scrollView.tile()
        return (coordinator, scrollView)
    }

    private func type(_ text: String, into coordinator: ComposerTextView.Coordinator) {
        coordinator.textView?.string = text
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    /// The flash: an enabled, auto-hiding scroller showed for the frame in which the
    /// text was taller than the not-yet-grown view. Below the cap it must never be on,
    /// and the new height must reach SwiftUI in the same pass.
    @Test func growingBelowTheCapNeverEnablesTheScroller() {
        let box = Box()
        let (coordinator, scrollView) = makeView(box)
        var lines: [String] = []
        var last: CGFloat = 0
        for line in 1...5 {
            lines.append("line \(line)")
            type(lines.joined(separator: "\n"), into: coordinator)
            #expect(!scrollView.hasVerticalScroller, "line \(line)")
            #expect(box.height > last, "the height arrives synchronously (line \(line))")
            last = box.height
        }
        #expect(last <= 170)
    }

    /// Typing Chinese moved the lines above up and down: an input method's edits scroll
    /// the text view to the caret, and while the SwiftUI frame is still a line short that
    /// scrolled the text a few points. Below the cap the text stays at the top.
    @Test func belowTheCapTheTextNeverScrolls() throws {
        let box = Box()
        let (coordinator, scrollView) = makeView(box)
        let textView = try #require(coordinator.textView)
        type("First line: English\n第二行 mixed 中文\n", into: coordinator)
        // The frame not grown yet: shorter than the three lines.
        scrollView.frame.size.height = box.height - 10
        scrollView.tile()
        textView.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        #expect(scrollView.contentView.bounds.minY == 0)
        textView.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        textView.scrollRangeToVisible(textView.selectedRange())
        #expect(scrollView.contentView.bounds.minY == 0)

        // Past the cap it scrolls to the caret as before.
        type((1...40).map { "line \($0)" }.joined(separator: "\n"), into: coordinator)
        scrollView.frame.size.height = 170
        scrollView.tile()
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        #expect(scrollView.contentView.bounds.minY > 0)
    }

    /// Nothing that starts when typing pauses (the first key after a pause was slow).
    @Test func noWorkStartsWhenTypingPauses() throws {
        let (coordinator, _) = makeView(Box())
        let textView = try #require(coordinator.textView)
        #expect(textView.inlinePredictionType == .no)
        #expect(!textView.isAutomaticTextCompletionEnabled)
        #expect(!textView.isGrammarCheckingEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
    }

    /// Latin, Chinese, mixed, emoji and marked text: every line the font's height.
    @Test func everyLineIsTheFontsHeight() throws {
        let box = Box()
        let (coordinator, _) = makeView(box)
        let textView = try #require(coordinator.textView)
        let layoutManager = try #require(textView.layoutManager)
        type("Latin only\n中文一行\nmixed 中英 text\n😀 emoji\n", into: coordinator)
        textView.setMarkedText("zhong wen", selectedRange: NSRange(location: 9, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        layoutManager.ensureLayout(for: try #require(textView.textContainer))
        var heights: [CGFloat] = []
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) {
            rect, _, _, _, _ in heights.append(rect.height)
        }
        let line = layoutManager.defaultLineHeight(for: try #require(textView.font))
        #expect(heights.count == 5)
        #expect(heights.allSatisfy { $0 == line }, "\(heights)")
        let composing = box.height
        textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(box.height == composing, "committing the candidate changed the height")
    }

    @Test func pastTheCapTheScrollerAppearsAndGoesAgain() {
        let box = Box()
        let (coordinator, scrollView) = makeView(box)
        type((1...40).map { "line \($0)" }.joined(separator: "\n"), into: coordinator)
        #expect(box.height > 170)
        #expect(scrollView.hasVerticalScroller)
        type("short again", into: coordinator)
        #expect(!scrollView.hasVerticalScroller)
    }
}
