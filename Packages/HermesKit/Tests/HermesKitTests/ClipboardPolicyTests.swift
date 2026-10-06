import Foundation
import Testing

@testable import HermesKit

/// What a paste attaches, for the clipboards people actually paste images from.
/// Type lists are the uniform type identifiers each source puts on the macOS pasteboard.
@Suite struct ClipboardPolicyTests {
    private func decide(_ types: [String], string: String? = nil, files: [String] = []) -> ClipboardPolicy.Decision {
        ClipboardPolicy.decide(.init(types: types, string: string, fileURLs: files.map { URL(fileURLWithPath: $0) }))
    }

    @Test func screenshotToTheClipboard() {
        #expect(decide(["public.png"]) == .imageData(type: "public.png"))
    }

    @Test func previewCopy() {
        #expect(decide(["public.tiff", "com.adobe.pdf"]) == .imageData(type: "public.tiff"))
    }

    @Test func browserCopyImage() {
        // Safari: the picture, its URL as a URL and as text.
        #expect(decide(["public.tiff", "public.url", "public.utf8-plain-text"], string: "https://example.com/cat.png")
            == .imageData(type: "public.tiff"))
        // Chrome: PNG and an <img> tag.
        #expect(decide(["public.png", "public.html"]) == .imageData(type: "public.png"))
        // Slack and others: a link beside the image.
        #expect(decide(["public.png", "public.utf8-plain-text"], string: "https://files.slack.com/x/cat.png")
            == .imageData(type: "public.png"))
    }

    @Test func aStringThatIsJustTheFileName() {
        #expect(decide(["public.png", "public.utf8-plain-text"], string: "Screenshot 2026-10-06 at 10.00.00.png")
            == .imageData(type: "public.png"))
    }

    @Test func finderCopy() {
        // An image file: its URL, its name as text, its icon as TIFF. The file is attached.
        #expect(decide(["public.file-url", "public.utf8-plain-text", "public.tiff"], string: "cat.heic",
                       files: ["/Users/u/Pictures/cat.heic"]) == .files([URL(fileURLWithPath: "/Users/u/Pictures/cat.heic")]))
        // Other files: the icon is not what the user meant.
        #expect(decide(["public.file-url", "public.utf8-plain-text", "public.tiff"], string: "report.pdf",
                       files: ["/Users/u/report.pdf"]) == .text)
        // A mix: the images among them.
        #expect(decide(["public.file-url"], files: ["/u/a.png", "/u/b.pdf"]) == .files([URL(fileURLWithPath: "/u/a.png")]))
    }

    @Test func realTextWinsOverItsPicture() {
        // A spreadsheet range, a rich-text selection: text and a picture of it.
        #expect(decide(["public.utf8-plain-text", "public.rtf", "public.tiff"], string: "name\tqty\napples\t3") == .text)
        #expect(decide(["public.utf8-plain-text", "public.html", "public.png"], string: "Look at this chart") == .text)
    }

    @Test func plainText() {
        #expect(decide(["public.utf8-plain-text"], string: "hello") == .text)
        #expect(decide([]) == .text)
    }
}
