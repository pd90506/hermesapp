import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// The second review's probes (R1-R6) as regressions, on `ChatComposer`'s slash
/// lookup, keys and sends. Return is `acceptSlashSuggestionFromKey(isTab: false)`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerSlashFollowUpTests {
    private let connections = ConnectionKeeper()

    private func openChat(_ gateway: ScriptedGateway) async throws -> ChatSession {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return try await connection.newSession()
    }

    /// R1: the view cancels a lookup on the next keystroke (`.task(id: draft)`), and the
    /// call throws `CancellationError`. The rows shown stay up, as on Desktop.
    @Test func aCancelledLookupKeepsTheRows() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { params in
            params["text"]?.stringValue == "/s"
                ? .result(["items": [["text": "/save"], ["text": "/stop"]], "replace_from": 1])
                : nil
        }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/s"
        await composer.updateSlashSuggestions()

        composer.draft = "/st"
        let lookup = Task { await composer.updateSlashSuggestions() }
        #expect(await eventually { gateway.params("complete.slash").contains { $0["text"] == "/st" } })
        composer.draft = "/sto"
        lookup.cancel()
        await lookup.value
        #expect(composer.slashIsOpen)
        #expect(composer.slashSuggestions.map(\.item.text) == ["/save", "/stop"])
    }

    /// R2: the user arrows to `/stop` on the stale bare list while `/s` is looked up.
    /// When the answer lands, the highlight stays on `/stop`, and Return takes it.
    @Test func anArrowedPickSurvivesTheAnswerLanding() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { _ in nil }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/"
        await composer.updateSlashSuggestions()
        #expect(composer.slashSuggestions.map(\.item.text).prefix(3) == ["/new", "/save", "/stop"])

        composer.draft = "/s"
        let lookup = Task { await composer.updateSlashSuggestions() }
        #expect(await eventually { gateway.params("complete.slash").count == 1 })
        composer.moveSlashSelection(1)
        composer.moveSlashSelection(1)
        #expect(composer.slashSuggestions[composer.slashSelection].item.text == "/stop")
        gateway.transport.respond(to: gateway.log.requests("complete.slash")[0],
                                  result: ["items": [["text": "/save"], ["text": "/stop"]], "replace_from": 1])
        await lookup.value
        #expect(composer.slashSuggestions.map(\.item.text) == ["/save", "/stop"])
        #expect(composer.slashSelection == 1)
        #expect(composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/stop ")
    }

    /// R2: if the arrowed row is not in the answer, nothing counts as picked: the
    /// highlight goes to row 0, and in a free-text argument Return sends.
    @Test func aPickThatIsGoneIsDropped() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { params in
            params["text"]?.stringValue == "/goal s"
                ? .result(["items": [["text": "status"], ["text": "set"]], "replace_from": 6])
                : nil
        }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/goal s"
        await composer.updateSlashSuggestions()

        composer.draft = "/goal st"
        let lookup = Task { await composer.updateSlashSuggestions() }
        #expect(await eventually { gateway.params("complete.slash").count == 2 })
        composer.moveSlashSelection(1)  // `/goal set`, on the list for `/goal s`
        gateway.transport.respond(to: gateway.log.requests("complete.slash")[1],
                                  result: ["items": [["text": "status"]], "replace_from": 6])
        await lookup.value
        #expect(composer.slashSelection == 0)
        #expect(!composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/goal st")
    }

    /// R3: the slash was deleted before the view closed the list: Return sends the
    /// prompt as typed rather than turning it into a command.
    @Test func returnOnANonCandidateDraftSends() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash", result: ["items": [["text": "/save"], ["text": "/stop"]], "replace_from": 1])
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/s"
        await composer.updateSlashSuggestions()
        composer.draft = "s"
        #expect(!composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(!composer.acceptSlashSuggestionFromKey(isTab: true))
        #expect(composer.draft == "s")
    }

    /// R4: an answer to a request made before a catalog reload is not cached.
    @Test func anAnswerFromBeforeAReloadIsNotCached() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { _ in nil }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/s"
        let lookup = Task { await composer.updateSlashSuggestions() }
        #expect(await eventually { gateway.params("complete.slash").count == 1 })
        composer.draft = ""
        await composer.loadSlashCommands()
        gateway.transport.respond(to: gateway.log.requests("complete.slash")[0],
                                  result: ["items": [["text": "/save"]], "replace_from": 1])
        await lookup.value
        composer.draft = "/s"
        #expect(composer.slashUpdateNeedsRequest)
    }

    /// R5: `/help` while the catalog is still loading loads it rather than saying
    /// commands are unavailable.
    @Test func helpWhileTheCatalogLoads() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog") { _ in nil }
        let session = try await openChat(gateway)
        let composer = ChatComposer(session: session)
        let loading = Task { await composer.loadSlashCommands() }
        #expect(await eventually { gateway.params("commands.catalog").count == 1 })

        composer.draft = "/help"
        let helping = Task { await composer.submitSlash() }
        #expect(await eventually { gateway.params("commands.catalog").count == 2 })
        for frame in gateway.log.requests("commands.catalog") {
            gateway.transport.respond(to: frame, result: composerSlashCatalog)
        }
        _ = await helping.value
        await loading.value
        let note = session.transcript.items.last?.text ?? ""
        #expect(note.hasPrefix("Available commands:"))
        #expect(note.contains("/compress — Compress this conversation context"))
    }

    /// Q1: a command that fails never changes what was typed since. Put in front of
    /// it, the next Return would run the command with that prose as its argument.
    /// Into an empty draft, the command comes back for a retry.
    @Test func aFailedCommandLeavesTypedTextAlone() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("session.compress") { _ in nil }
        let session = try await openChat(gateway)
        let composer = ChatComposer(session: session)
        await composer.loadSlashCommands()

        composer.draft = "/compress"
        let compressing = Task { await composer.submitSlash() }
        #expect(await eventually { gateway.params("session.compress").count == 1 })
        composer.draft = "please explain the migration bug"
        gateway.transport.respondError(to: gateway.log.requests("session.compress")[0], code: 5000, message: "boom")
        _ = await compressing.value
        #expect(composer.draft == "please explain the migration bug")
        #expect(!SlashCommand.isCommand(composer.draft))
        #expect(session.transcript.items.last?.text.hasPrefix("/compress: ") == true)

        composer.draft = "/compress"
        let again = Task { await composer.submitSlash() }
        #expect(await eventually { gateway.params("session.compress").count == 2 })
        gateway.transport.respondError(to: gateway.log.requests("session.compress")[1], code: 5000, message: "boom")
        _ = await again.value
        #expect(composer.draft == "/compress")
    }

    /// R6: a slow `/compress` does not hold the composer. `/stop` goes out while it
    /// runs (Desktop sends slash commands at once, `use-composer-submit.ts:291-315`),
    /// and no send is shown as in flight, so there is no Cancel Send to press.
    @Test func stopGoesOutDuringASlowCompress() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("session.compress") { _ in nil }
        gateway.on("session.interrupt", result: ["status": "interrupted", "interrupted": true])
        gateway.on("process.stop", result: ["killed": 0])
        let session = try await openChat(gateway)
        let composer = ChatComposer(session: session)
        await composer.loadSlashCommands()

        composer.draft = "/compress"
        let compressing = Task { await composer.submitSlash() }
        #expect(await eventually { gateway.params("session.compress").count == 1 })
        #expect(!composer.isSubmitting)

        composer.draft = "/stop"
        #expect(composer.canSubmit)
        _ = await composer.submitSlash()
        #expect(gateway.params("session.interrupt") == [["session_id": "sid-1"]])
        #expect(session.transcript.items.last?.text == "Stopped the active turn.\nNo background processes to stop.")

        gateway.transport.respond(to: gateway.log.requests("session.compress")[0], result: ["status": "ok", "removed": 0])
        _ = await compressing.value
        #expect(session.transcript.items.last?.text == "nothing to compress")
    }
}
