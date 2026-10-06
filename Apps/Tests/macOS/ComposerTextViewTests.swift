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
private func filename(_ source: ImageSource) -> String {
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
        var attached: [ImageSource] = []
        textView.onImages = { attached = $0 }

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
        textView.onImages = { _ in attached = true }

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

    /// Finder's Copy of a PDF: its icon is not what the user meant.
    @Test func finderCopyOfAnotherFileStaysText() {
        let board = pasteboard()
        board.writeObjects([URL(fileURLWithPath: "/tmp/report.pdf") as NSURL])
        board.addTypes([.tiff], owner: nil)
        board.setData(tiffBytes, forType: .tiff)
        #expect(ImageLoader.sources(from: board).isEmpty)
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
            maxHeight: 170, focusRequest: 0, onSubmit: {}, onImages: { _ in }, onImageProviders: { _ in })
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
