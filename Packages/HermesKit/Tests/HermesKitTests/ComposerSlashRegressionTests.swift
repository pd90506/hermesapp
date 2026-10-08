import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// `commands.catalog` as `methods_tools.py:503-537` builds it, with the
/// `argument_mode` / `desktop` metadata these cases turn on: `/goal` takes free
/// text with subcommands (`mixed`), `/voice` is refused in a GUI (`composer-voice`).
let composerSlashCatalog: JSONValue = [
    "pairs": [["/new", "Start a new session"], ["/save", "Save the transcript"], ["/stop", "Stop the turn"],
              ["/compress", "Compress this conversation context"], ["/goal", "Set a standing goal"],
              ["/undo", "Undo the last turn"], ["/personality", "Set a personality"],
              ["/handoff", "Hand off to a platform"], ["/voice", "Toggle voice mode"],
              ["/skills", "Manage skills"]],
    "sub": [:],
    "canon": ["/compact": "/compress", "/reset": "/new", "/clear": "/new"],
    "commands": [
        "/new": ["argument_mode": nil, "desktop": nil],
        "/save": ["argument_mode": nil, "desktop": nil],
        "/stop": ["argument_mode": nil, "desktop": nil],
        "/compress": ["argument_mode": "text", "desktop": nil],
        "/goal": ["argument_mode": "mixed", "desktop": nil],
        "/undo": ["argument_mode": nil, "desktop": nil],
        "/personality": ["argument_mode": "options", "desktop": nil],
        "/handoff": ["argument_mode": "options", "desktop": nil],
        "/voice": ["argument_mode": "options", "desktop": "composer-voice"],
        "/skills": ["argument_mode": "options", "desktop": "settings",
                    "desktop_subcommands": ["pending", "approve", "reject", "diff", "approval"]],
    ],
    "categories": [
        ["name": "Session", "pairs": [["/new", "Start a new session"], ["/save", "Save the transcript"],
                                      ["/stop", "Stop the turn"], ["/compress", "Compress this conversation context"],
                                      ["/goal", "Set a standing goal"], ["/undo", "Undo the last turn"]]],
        ["name": "Configuration", "pairs": [["/personality", "Set a personality"], ["/handoff", "Hand off to a platform"],
                                            ["/voice", "Toggle voice mode"]]],
        ["name": "Tools & Skills", "pairs": [["/skills", "Manage skills"]]],
    ],
    "skills": [:], "skill_count": 0, "warning": "",
]

/// The review's probes for the slash composer (P1-P4, P6), as regressions. Return
/// is `acceptSlashSuggestionFromKey(isTab: false)`; `false` means the view sends.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerSlashRegressionTests {
    private let connections = ConnectionKeeper()

    private func openChat(_ gateway: ScriptedGateway) async throws -> ChatSession {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return try await connection.newSession()
    }

    /// P1: the list for `/s` is still up while `/stop`'s answer is pending. Return
    /// keeps the typed command (Desktop: an exact row wins, `composer-utils.ts:148-152`).
    @Test func returnKeepsATypedCommandOverAStaleHighlight() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { params in
            params["text"]?.stringValue == "/s"
                ? .result(["items": [["text": "/save"], ["text": "/stop"]], "replace_from": 1])
                : nil  // anything else is held
        }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/s"
        await composer.updateSlashSuggestions()
        #expect(composer.slashSuggestions.map(\.item.text) == ["/save", "/stop"])

        composer.draft = "/stop"
        let pending = Task { await composer.updateSlashSuggestions() }
        defer { pending.cancel() }
        #expect(await eventually { gateway.params("complete.slash").contains { $0["text"] == "/stop" } })
        #expect(composer.slashIsOpen)
        #expect(composer.slashSuggestions.map(\.item.text) == ["/save", "/stop"])
        #expect(composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/stop ")

        // Nothing in the old list extends the text: Return sends it as typed.
        composer.draft = "/s"
        await composer.updateSlashSuggestions()
        composer.draft = "/sx"
        #expect(!composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/sx")
        // The highlight (`/save`) does not extend `/st`; the one row that does wins.
        composer.draft = "/st"
        #expect(composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/stop ")
    }

    /// P1, free text: in `/goal s` Return sends; only an arrowed row or Tab
    /// takes `/goal status` (`composer-utils.ts:187-205`).
    @Test func returnSendsAFreeTextArgumentUnlessARowWasPicked() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        // `replace_from` is after the last space (`methods_complete.py:330`).
        gateway.on("complete.slash", result: ["items": [["text": "status"], ["text": "clear"]], "replace_from": 6])
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/goal s"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)

        #expect(!composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/goal s")

        composer.moveSlashSelection(1)
        composer.moveSlashSelection(-1)
        #expect(composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/goal status")

        composer.draft = "/goal s"
        await composer.updateSlashSuggestions()
        #expect(composer.acceptSlashSuggestionFromKey(isTab: true))
        #expect(composer.draft == "/goal status")
    }

    /// P2: what is typed while a slow command runs stays, for an output and for a
    /// prefill (which goes in front of it).
    @Test func draftTypedWhileASlashCommandRunsIsKept() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("session.compress") { _ in nil }
        gateway.on("slash.exec") { _ in nil }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()

        composer.draft = "/compress"
        let compressing = Task { await composer.submitSlash() }
        #expect(await eventually { !gateway.params("session.compress").isEmpty })
        composer.draft = "next question"
        // `session.compress` (`methods_session.py:2160-2190`).
        gateway.transport.respond(to: gateway.log.requests("session.compress")[0], result: ["status": "ok", "removed": 3])
        _ = await compressing.value
        #expect(composer.draft == "next question")

        composer.draft = "/undo"
        let undoing = Task { await composer.submitSlash() }
        #expect(await eventually { !gateway.params("slash.exec").isEmpty })
        composer.draft = "typed meanwhile"
        gateway.transport.respond(to: gateway.log.requests("slash.exec")[0],
                                  result: ["type": "prefill", "message": "my last message"])
        #expect(await undoing.value == .prefill("my last message"))
        #expect(composer.draft == "my last message\ntyped meanwhile")
    }

    /// P3: `/stop` needs no catalog; one still loading must not refuse it.
    @Test func stopRunsWhileTheCatalogIsStillLoading() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog") { _ in nil }
        gateway.on("session.interrupt", result: ["status": "interrupted", "interrupted": true])
        gateway.on("process.stop", result: ["killed": 0])
        let session = try await openChat(gateway)
        let composer = ChatComposer(session: session)
        let loading = Task { await composer.loadSlashCommands() }
        defer { loading.cancel() }
        #expect(await eventually { !gateway.params("commands.catalog").isEmpty })

        composer.draft = "/stop"
        _ = await composer.submitSlash()
        #expect(gateway.params("session.interrupt") == [["session_id": "sid-1"]])
        #expect(session.transcript.items.last?.text == "Stopped the active turn.\nNo background processes to stop.")
    }

    /// P4: a GUI-refused command is not listed (`desktop-slash-commands.ts:749`), so
    /// Return sends it and Desktop's reason shows.
    @Test func aRefusedCommandIsNotListedAndReturnSendsIt() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash", result: ["items": [["text": "/voice"]], "replace_from": 1])
        let session = try await openChat(gateway)
        let composer = ChatComposer(session: session)
        await composer.loadSlashCommands()
        composer.draft = "/voice"
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)

        #expect(!composer.acceptSlashSuggestionFromKey(isTab: false))
        _ = await composer.submitSlash()
        #expect(session.transcript.items.last?.text == "Voice chat isn't available in this app yet: Hermes's gateway voice methods record on the server's own microphone.")
        #expect(composer.draft.isEmpty)
    }

    /// P6: Escape hides the list for that text only until the next send.
    @Test func escapeSuppressionEndsWithTheSend() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash", result: ["items": [["text": "/save"]], "replace_from": 1])
        gateway.on("session.save", result: ["file": "/tmp/x.json"])
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/save"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)
        composer.dismissSlashSuggestions()
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)

        _ = await composer.submitSlash()
        composer.draft = "/save"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)
    }
}
