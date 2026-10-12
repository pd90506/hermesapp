import Foundation
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `MEDIA:` tags, as Desktop's `renderMediaTags` / `mediaTagValues` read them
/// (`apps/desktop/src/lib/chat-messages/parts.ts:121-300`).
@Suite struct MediaTagsTests {
    private func paths(_ text: String) -> [String] { MediaTags.extract(text).files.map(\.path) }

    @Test func aTagOnItsOwnLineBecomesACardAndLeavesTheText() {
        let (text, files) = MediaTags.extract("Here is the report.\n\nMEDIA:/tmp/out/report.pdf\n\nAnything else?")
        #expect(files == [DeliveredFile(path: "/tmp/out/report.pdf")])
        #expect(text == "Here is the report.\n\nAnything else?")
        #expect(files[0].name == "report.pdf" && files[0].kind == .pdf && !files[0].isImage)
    }

    @Test func anInlineTagBecomesTheFileName() {
        let (text, files) = MediaTags.extract("I saved MEDIA:/tmp/chart.png for you.")
        #expect(text == "I saved chart.png for you.")
        #expect(files.map(\.path) == ["/tmp/chart.png"] && files[0].isImage)
    }

    @Test func sentencePunctuationIsNotPartOfThePath() {
        #expect(paths("Open MEDIA:/tmp/a.pdf.") == ["/tmp/a.pdf"])
        #expect(MediaTags.extract("Open MEDIA:/tmp/a.pdf.").text == "Open a.pdf.")
        #expect(paths("See MEDIA:relative/notes.txt, then reply") == ["relative/notes.txt"])
    }

    @Test func spacesInsideAPathWithAKnownExtension() {
        #expect(paths("MEDIA:/Users/u/My Files/Q3 report.xlsx") == ["/Users/u/My Files/Q3 report.xlsx"])
    }

    @Test func quotedPaths() {
        #expect(paths("MEDIA:`/tmp/odd name!.log`") == ["/tmp/odd name!.log"])
        #expect(paths(#"MEDIA:"/tmp/a b.weird""#) == ["/tmp/a b.weird"])
        #expect(paths("MEDIA:'/tmp/stop!.md'") == ["/tmp/stop!.md"])
    }

    @Test func severalTagsInOrderEachOnce() {
        let text = "MEDIA:/a/one.png\nMEDIA:/a/two.csv\nAgain: MEDIA:/a/one.png"
        #expect(paths(text) == ["/a/one.png", "/a/two.csv"])
    }

    @Test func notAPathStaysText() {
        #expect(MediaTags.extract("MEDIA: ... is how files are sent").files.isEmpty)
        #expect(MediaTags.extract("plain text").text == "plain text")
    }

    @Test func tagsInCodeBlocksAreExamples() {
        let text = "Write it like this:\n```\nMEDIA:/path/to/file.pdf\n```\nMEDIA:/real/file.pdf"
        let (shown, files) = MediaTags.extract(text)
        #expect(files.map(\.path) == ["/real/file.pdf"])
        #expect(shown == "Write it like this:\n```\nMEDIA:/path/to/file.pdf\n```")
    }

    @Test func whileStreamingAnUnfinishedLastLineWaits() {
        let partial = MediaTags.extract("Done.\nMEDIA:/tmp/rep", isStreaming: true)
        #expect(partial.files.isEmpty && partial.text == "Done.")
        let complete = MediaTags.extract("Done.\nMEDIA:/tmp/report.pdf\n", isStreaming: true)
        #expect(complete.files.map(\.path) == ["/tmp/report.pdf"])
    }

    /// A reply as Hermes wrote it (the icon chat, 2026-10-12): each card belongs
    /// where its tag was, under the bullet it follows.
    @Test func filesShowWhereTheirTagsWere() {
        let text = """
            Done: a black icon.

            MEDIA:/s/icon/preview.png

            Downloads:
            - **iOS**: 1024×1024.
            MEDIA:/s/icon/ios-1024.png
            - **macOS**: rounded corners.
            MEDIA:/s/icon/macos-1024.png
            - **SVG master**
            MEDIA:/s/icon/master.svg

            Does this direction work?
            """
        func file(_ path: String) -> DeliveredFile { DeliveredFile(path: path) }
        #expect(MediaTags.segments(text) == [
            .markdown("Done: a black icon."),
            .files([file("/s/icon/preview.png")]),
            .markdown("Downloads:\n- **iOS**: 1024×1024."),
            .files([file("/s/icon/ios-1024.png")]),
            .markdown("- **macOS**: rounded corners."),
            .files([file("/s/icon/macos-1024.png")]),
            .markdown("- **SVG master**"),
            .files([file("/s/icon/master.svg")]),
            .markdown("Does this direction work?"),
        ])
        #expect(file("/s/icon/master.svg").isImage && file("/s/icon/ios-1024.png").isImage)
    }

    @Test func adjacentTagsShareOneRowAndAnInlineTagFollowsItsLine() {
        #expect(MediaTags.segments("Here:\nMEDIA:/a/1.png\nMEDIA:/a/2.png") == [
            .markdown("Here:"), .files([DeliveredFile(path: "/a/1.png"), DeliveredFile(path: "/a/2.png")]),
        ])
        #expect(MediaTags.segments("See MEDIA:/a/r.pdf now.\nBye") == [
            .markdown("See r.pdf now."), .files([DeliveredFile(path: "/a/r.pdf")]), .markdown("Bye"),
        ])
    }

    @Test func assistantItemsListTheirFiles() {
        var item = TranscriptItem(id: "a", role: .assistant, text: "MEDIA:/tmp/x.zip")
        #expect(item.deliveredFiles.map(\.path) == ["/tmp/x.zip"])
        item.role = .user
        #expect(item.deliveredFiles.isEmpty)
    }

    @Test func fileKinds() {
        #expect(FileKind(filename: "a.PDF") == .pdf)
        #expect(FileKind(filename: "data.csv") == .spreadsheet)
        #expect(FileKind(filename: "song.mp3") == .audio)
        #expect(FileKind(filename: "Makefile") == .other)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct FileDownloadTests {
    private func connector(_ http: RoutedHTTP) throws -> DashboardConnector {
        DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                           credential: .bearer(accessToken: "tok"), http: http)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func downloadsThroughTheFileRoute() async throws {
        let http = RoutedHTTP { path, bearer in
            path == "/api/fs/download" && bearer == "tok" ? (200, "%PDF-1.7") : (500, "")
        }
        let url = try await connector(http).downloadFile(path: "notes/a.pdf", profile: "coder", sessionID: "stored-1")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == Data("%PDF-1.7".utf8))
        #expect(query(http.requests[0]) == ["path": "notes/a.pdf", "profile": "coder", "session_id": "stored-1"])
    }

    @Test func failuresThrowAndLeaveNoFile() async throws {
        let http = RoutedHTTP { _, _ in (404, #"{"detail":"File not found"}"#) }
        await #expect(throws: DashboardError.self) {
            _ = try await connector(http).downloadFile(path: "/tmp/gone.pdf", profile: nil, sessionID: nil)
        }
    }
}

/// Composer sources for pastes and drops (`ClipboardPolicy`) and the paths of
/// attached files (`ComposerFile.refPath`).
@Suite struct ComposerFilePathTests {
    @Test func refPathIsTheReferenceValue() {
        #expect(ComposerFile(name: "a b.pdf", byteCount: 1, refText: "@file:`attachments/a b.pdf`").refPath
            == "attachments/a b.pdf")
        #expect(ComposerFile(name: "c.csv", byteCount: 1, refText: "@file:/srv/c.csv").refPath == "/srv/c.csv")
    }
}
