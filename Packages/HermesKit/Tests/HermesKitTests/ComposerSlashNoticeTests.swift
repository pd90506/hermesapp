import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// What shows in place of the slash list when there are no rows: Desktop's empty state
/// ("No matches." with "Try /help", `trigger-popover.tsx:164-185`) or why the lookup or the
/// catalog failed, against the captured real responses (`RealSlashResponses`).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerSlashNoticeTests {
    private let connections = ConnectionKeeper()

    private func composer(_ gateway: ScriptedGateway) async throws -> ChatComposer {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return ChatComposer(session: try await connection.newSession())
    }

    /// No match: the list closes and Desktop's empty state shows; it goes once
    /// something matches again.
    @Test func noMatchShowsDesktopsEmptyState() async throws {
        let composer = try await composer(try realSlashGateway())
        await composer.loadSlashCommands()
        composer.draft = "/zzz"
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)
        #expect(composer.slashNotice == "No matches. Try /help.")
        composer.draft = "/com"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)
        #expect(composer.slashNotice == nil)
        composer.dismissSlashSuggestions()
        #expect(composer.slashNotice == nil)
    }

    /// A failed lookup never leaves a list open, and says why; Esc or a change clears it.
    @Test func aFailedLookupIsShownNotSilent() async throws {
        let gateway = try realSlashGateway()
        gateway.on("complete.slash") { params in
            params["text"]?.stringValue == "/com"
                ? .result(try! realSlashJSON(RealSlashResponses.slashCom))
                : .error(code: 5020, message: "completer exploded")
        }
        let composer = try await composer(gateway)
        await composer.loadSlashCommands()
        composer.draft = "/com"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)
        composer.draft = "/co"
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)
        #expect(composer.slashSuggestions.isEmpty)
        #expect(composer.slashNotice?.hasPrefix("Couldn't look up commands: ") == true)
        #expect(composer.slashNotice?.contains("completer exploded") == true)
        composer.draft = "hello"
        await composer.updateSlashSuggestions()
        #expect(composer.slashNotice == nil)
    }

    /// A catalog that failed to load says so when `/` is typed, instead of nothing.
    @Test func aFailedCatalogIsShownNotSilent() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog") { _ in .error(code: 5000, message: "skills scan failed") }
        let composer = try await composer(gateway)
        await composer.loadSlashCommands()
        composer.draft = "/"
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)
        #expect(composer.slashNotice?.hasPrefix("Couldn't load commands: ") == true)
        composer.dismissSlashSuggestions()
        await composer.updateSlashSuggestions()
        #expect(composer.slashNotice == nil)
    }
}
