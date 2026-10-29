import XCTest

#if os(macOS)
import AppKit

/// Two images pasted into the composer upload as soon as they are cards (a ring on each
/// meanwhile) and Send waits for them; on Send the cards leave the composer at once. The
/// prompt shows both images, apart from its caption, live and once its row is read back.
/// The user's reports (2026-10-29): the cards stayed until the send was done, and a
/// stored prompt with two images showed Hermes's model-only hints as text.
/// Skipped without `HERMES_UITEST_URL` and `HERMES_UITEST_TOKEN`.
final class ImageSendUITests: XCTestCase {
    @MainActor
    func testTwoImagesUploadWhenAttachedAndShowInThePrompt() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"] else {
            throw XCTSkip("No live server (run scripts/vm-test.sh)")
        }
        let tag = Int.random(in: 1000...9999)
        let files = try ["red", "blue"].enumerated().map { index, name in
            try png(named: "\(name)-\(tag).png", color: index == 0 ? .systemRed : .systemBlue)
        }
        addTeardownBlock { for file in files { try? FileManager.default.removeItem(at: file) } }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_URL"] = url
        app.launchEnvironment["HERMES_UITEST_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PROFILE"] = env["HERMES_UITEST_PROFILE"] ?? "hermesapp-test"
        app.launchEnvironment["HERMES_UITEST_SERVERS"] = "1"
        app.launchWithMainWindow()
        defer { app.terminate() }

        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "connected, Sessions page shown")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: newChat)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "New chat enabled")
        newChat.click()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer shown")
        composer.click()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(files.map { $0 as NSURL })
        composer.typeKey("v", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        let cards = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH 'Image red-' OR label BEGINSWITH 'Image blue-' OR value BEGINSWITH 'Image red-' OR value BEGINSWITH 'Image blue-'"))
        XCTAssertTrue(eventually(timeout: 15) { cards.count == 2 }, "two image cards")
        attach(app, "two image cards, uploading or uploaded")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(eventually(timeout: 30) { send.isEnabled }, "Send once both are uploaded")

        let marker = "IMG-\(tag)"
        composer.typeText("Reply with exactly \(marker) and nothing else. Do not use tools.")
        send.click()
        // The cards leave the composer as the send starts.
        XCTAssertTrue(eventually(timeout: 5) {
            !app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch.exists
        }, "the cards left the composer")

        let reply = app.textViews.matching(NSPredicate(format: "value == %@", marker))
        let deadline = Date().addingTimeInterval(150)
        while reply.count < 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        if reply.count < 1 { attach(app, "no reply") }
        XCTAssertGreaterThanOrEqual(reply.count, 1, "reply \(marker) shown")
        // The turn's rows are read back and replace the live bubble.
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        let shown = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Image '"))
        XCTAssertEqual(shown.count, 2, "both images on the stored prompt")
        let hints = app.descendants(matching: .any).matching(NSPredicate(
            format: "value CONTAINS 'The user attached an image' OR label CONTAINS 'The user attached an image'"))
        XCTAssertEqual(hints.count, 0, "no model hints as text")
        attach(app, "the prompt with two images and its caption")
    }

    /// A small PNG of one colour in the temporary folder.
    private func png(named name: String, color: NSColor) throws -> URL {
        let image = NSImage(size: NSSize(width: 160, height: 120), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let data = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
