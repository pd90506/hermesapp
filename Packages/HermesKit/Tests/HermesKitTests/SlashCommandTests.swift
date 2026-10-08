import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// `commands.catalog` as `methods_tools.py:503-537` builds it: registry
/// categories with `commands` metadata, "User commands" from `quick_commands`
/// (:460-471), "Plugin commands" (:474-486), and skills only in `pairs` and
/// `skills` (:489-500).
private let catalogPayload: JSONValue = [
    "pairs": [["/compress", "Compress this conversation context"], ["/usage", "Show token usage"],
              ["/model", "Switch model"], ["/voice", "Toggle voice mode"], ["/deploy", "exec: ./deploy.sh"],
              ["/standup", "Daily standup notes"]],
    "sub": [:],
    "canon": ["/compact": "/compress"],
    "commands": [
        "/compress": ["argument_mode": "text", "desktop": nil],
        "/usage": ["argument_mode": nil, "desktop": nil],
        "/model": ["argument_mode": "options", "desktop": "hidden"],
        "/voice": ["argument_mode": "options", "desktop": "composer-voice"],
    ],
    "categories": [
        ["name": "Session", "pairs": [["/compress", "Compress this conversation context"], ["/usage", "Show token usage"],
                                      ["/model", "Switch model"]]],
        ["name": "Configuration", "pairs": [["/voice", "Toggle voice mode"]]],
        ["name": "User commands", "pairs": [["/deploy", "exec: ./deploy.sh"]]],
    ],
    "skills": ["/standup": ["usage": 3, "origin": "local"]],
    "skill_count": 1,
    "warning": "",
]

@Suite struct SlashCatalogTests {
    @Test func catalogListsCommandsQuickCommandsAndSkills() throws {
        let catalog = SlashCatalog(try catalogPayload.decode(CommandsCatalogResult.self))

        #expect(catalog.commands.map(\.name) == ["/compress", "/usage", "/voice", "/deploy", "/standup"])
        #expect(catalog.command(named: "deploy")?.kind == .quick)
        #expect(catalog.command(named: "/standup")?.kind == .skill)
        #expect(catalog.command(named: "/standup")?.category == "Skills")
        #expect(catalog.command(named: "/compress")?.argumentMode == "text")
        // A GUI can't run it: shown, but marked unavailable (`desktop-slash-commands.ts:440-483`).
        #expect(catalog.command(named: "/voice")?.unavailableReason == "Voice chat isn't available in this app yet: Hermes's gateway voice methods record on the server's own microphone.")
        #expect(catalog.command(named: "/model") == nil)  // `hidden`
        #expect(catalog.warning == nil)
    }

    @Test func recognisesAndParsesCommands() {
        #expect(SlashCommand.isCommand("/compress"))
        #expect(SlashCommand.isCommand("  /btw what now?"))
        #expect(!SlashCommand.isCommand("/usr/bin/env is missing"))
        #expect(!SlashCommand.isCommand("hello /compress"))
        #expect(SlashCommand.parse("/Title  My   chat ") == ("title", "My   chat"))
    }

    /// `replace_from` is 1 at the command stage and after the last space for an
    /// argument (`methods_complete.py:330`); argument items carry only the stub.
    @Test func acceptingACompletion() {
        let command = SlashCompletions(CompleteSlashResult(items: [SlashCompletionItem(text: "/compress")], replaceFrom: 1),
                                       text: "/comp")
        #expect(command.applying(command.items[0]) == "/compress")

        let argument = SlashCompletions(CompleteSlashResult(items: [SlashCompletionItem(text: "alice")], replaceFrom: 13),
                                        text: "/personality ali")
        #expect(argument.applying(argument.items[0]) == "/personality alice")
    }

    @Test func nativePopoverKeepsCatalogOrderAndGatesRows() throws {
        let catalog = SlashCatalog(try catalogPayload.decode(CommandsCatalogResult.self))
        #expect(SlashCommand.isCompletionCandidate("/"))
        #expect(SlashCommand.isCompletionCandidate("/compress more"))
        #expect(!SlashCommand.isCompletionCandidate("/usr/bin something"))
        #expect(!SlashCommand.isCompletionCandidate("hello /compress"))
        // A GUI-refused command is left out, as on Desktop (`desktop-slash-commands.ts:749`).
        #expect(catalog.suggestions(for: "/").map(\.item.text) == ["/compress", "/usage", "/deploy", "/standup"])

        let completion = SlashCompletions(CompleteSlashResult(items: [
            SlashCompletionItem(text: "/model"), SlashCompletionItem(text: "/compress"),
        ]), text: "/co")
        #expect(catalog.suggestions(for: "/co", completions: completion).map(\.item.text) == ["/compress"])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SlashRunTests {
    private let connections = ConnectionKeeper()

    private func openChat(_ gateway: ScriptedGateway) async throws -> ChatSession {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return try await connection.newSession()
    }

    @Test func composerOpensFiltersAndAcceptsWithoutTimers() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: catalogPayload)
        gateway.on("complete.slash", result: ["items": [["text": "/compress"]], "replace_from": 1])
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()
        composer.draft = "/"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)
        #expect(composer.slashSuggestions.first?.item.text == "/compress")
        composer.draft = "/comp"
        await composer.updateSlashSuggestions()
        #expect(composer.slashSuggestions.map(\.item.text) == ["/compress"])
        composer.acceptSlashSuggestion()
        #expect(composer.draft == "/compress ")
        #expect(!composer.slashIsOpen)
        #expect(gateway.params("prompt.submit").isEmpty)
    }

    @Test func failedCatalogNeverTurnsSlashIntoPrompt() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog") { _ in .error(code: 5000, message: "catalog unavailable") }
        let session = try await openChat(gateway)
        let composer = ChatComposer(session: session)
        await composer.loadSlashCommands()
        composer.draft = "/x"
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)
        let outcome = await composer.submitSlash()
        guard case .unavailable = outcome else { Issue.record("Expected unavailable"); return }
        #expect(session.transcript.items.last?.role == .system)
        #expect(gateway.params("prompt.submit").isEmpty)
    }

    @Test func loadsTheSessionsCatalogAndCompletes() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: catalogPayload)
        gateway.on("complete.slash", result: [
            "items": [["text": "/compress", "display": "/compress", "meta": "Compress this conversation context",
                       "kind": "command"]],
            "replace_from": 1,
        ])
        let session = try await openChat(gateway)

        let catalog = try await session.loadSlashCommands()
        let completions = try await session.completeSlash("/comp")

        #expect(gateway.params("commands.catalog") == [["session_id": "sid-1"]])
        #expect(gateway.params("complete.slash") == [["session_id": "sid-1", "text": "/comp"]])
        #expect(session.slashCatalog == catalog)
        #expect(completions.items.first?.kind == "command")
    }

    @Test func execOutputIsShownInTheTranscript() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec", result: ["output": "Tokens: 1,234", "warning": ""])
        let session = try await openChat(gateway)

        let outcome = try await session.runSlash("/usage")

        #expect(outcome == .output("Tokens: 1,234"))
        #expect(gateway.params("slash.exec") == [["session_id": "sid-1", "command": "usage"]])
        #expect(session.transcript.items.last?.role == .system)
        #expect(session.transcript.items.last?.text == "Tokens: 1,234")
    }

    /// `slash.exec` refuses a skill with 4018 (`methods_tools.py:1118-1196`);
    /// `command.dispatch` answers `{type:"skill", message, name, display}` (:718-746),
    /// and the expanded body is sent as a normal prompt showing `display`.
    @Test func skillBecomesAPrompt() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec") { _ in .error(code: 4018, message: "skill command: use command.dispatch for /standup") }
        gateway.on("command.dispatch", result: [
            "type": "skill", "name": "standup", "display": "/standup for the infra team",
            "message": "[SKILL: standup]\nWrite standup notes…\n\nfor the infra team",
        ])
        let session = try await openChat(gateway)

        let outcome = try await session.runSlash("/standup for the infra team")

        #expect(outcome == .submitted(display: "/standup for the infra team"))
        #expect(gateway.params("command.dispatch") == [["name": "standup", "arg": "for the infra team",
                                                        "session_id": "sid-1"]])
        #expect(gateway.params("prompt.submit") == [["session_id": "sid-1",
                                                     "text": "[SKILL: standup]\nWrite standup notes…\n\nfor the infra team"]])
        #expect(session.transcript.items.last?.text == "/standup for the infra team")
        #expect(session.transcript.isRunning)
    }

    @Test func aCommandRunWhileBusyIsQueued() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec", result: ["type": "send", "message": "Plan the migration", "display": "/plan migration"])
        let session = try await openChat(gateway)
        try await session.send("first")

        _ = try await session.runSlash("/plan migration")

        #expect(gateway.params("prompt.submit").last == ["session_id": "sid-1", "text": "Plan the migration",
                                                         "queued": true])
    }

    @Test func aliasesPrefillsAndNotices() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec") { params in
            switch params["command"]?.stringValue {
            case "ship now"?: return .result(["type": "alias", "target": "deploy"])
            case "deploy now"?: return .result(["type": "exec", "output": "deployed"])
            case "undo"?: return .result(["type": "prefill", "message": "my last message", "notice": "Undid 1 turn"])
            default: return .error(code: 5030, message: "worker failed")
            }
        }
        let session = try await openChat(gateway)

        #expect(try await session.runSlash("/ship now") == .output("deployed"))
        #expect(try await session.runSlash("/undo") == .prefill("my last message"))
        #expect(session.transcript.items.last?.text == "Undid 1 turn")
    }

    @Test func clientActionsAndUnavailableCommandsAreNotSent() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: catalogPayload)
        let session = try await openChat(gateway)
        try await session.loadSlashCommands()

        #expect(try await session.runSlash("/new") == .clientAction(name: "new", argument: ""))
        #expect(try await session.runSlash("/model gpt-5") == .clientAction(name: "model", argument: "gpt-5"))
        #expect(try await session.runSlash("/voice on") == .unavailable("Voice chat isn't available in this app yet: Hermes's gateway voice methods record on the server's own microphone."))
        #expect(gateway.params("slash.exec").isEmpty && gateway.params("command.dispatch").isEmpty)
    }

    // MARK: The catalog's gate

    /// `/skills` exposes only its review subcommands to a GUI; the CLI hub
    /// mutations must not be reachable (`desktop-slash-commands.ts:314-325,551-587`).
    /// The gate holds before the app ever loaded the catalog.
    @Test func subcommandsOutsideTheAllowlistAreRefused() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec", result: ["output": "2 staged writes"])
        let session = try await openChat(gateway)
        #expect(session.slashCatalog == nil)

        #expect(try await session.runSlash("/skills install evil-skill") == .unavailable(
            "/skills install is not available in this app — use the terminal for it. "
                + "Available here: pending, approve, reject, diff, approval."))
        #expect(try await session.runSlash("/skills") ==
                .unavailable("/skills needs a subcommand here: pending, approve, reject, diff, approval."))
        #expect(gateway.params("slash.exec").isEmpty)
        #expect(gateway.params("commands.catalog").count == 1)  // loaded once, on demand

        #expect(try await session.runSlash("/skills pending") == .output("2 staged writes"))
        #expect(gateway.params("slash.exec") == [["session_id": "sid-1", "command": "skills pending"]])
    }

    /// Aliases resolve through the catalog's `canon` before the gate.
    @Test func anAliasOfAnUnavailableCommandIsRefused() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: [
            "pairs": [["/voice", "Toggle voice mode"]], "sub": [:], "canon": ["/talk": "/voice"],
            "commands": ["/voice": ["argument_mode": "options", "desktop": "composer-voice"]],
            "categories": [["name": "Configuration", "pairs": [["/voice", "Toggle voice mode"]]]],
            "skills": [:], "skill_count": 0, "warning": "",
        ])
        let session = try await openChat(gateway)

        #expect(try await session.runSlash("/talk on") == .unavailable("Voice chat isn't available in this app yet: Hermes's gateway voice methods record on the server's own microphone."))
        #expect(gateway.params("slash.exec").isEmpty)
    }

    @Test func aCatalogThatFailsToLoadFailsClosed() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog") { _ in .error(code: 5020, message: "catalog unavailable") }
        let session = try await openChat(gateway)

        await #expect(throws: RPCError.self) { _ = try await session.runSlash("/usage") }
        #expect(gateway.params("slash.exec").isEmpty && gateway.params("command.dispatch").isEmpty)
    }

    /// Desktop shows the worker's error when the dispatch fallback only says
    /// "not a quick/plugin/skill command" (`slash.ts:430-463`).
    @Test func theWorkersErrorIsKeptWhenDispatchHasNothingToAdd() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec") { _ in .error(code: 5030, message: "slash worker timed out") }
        gateway.on("command.dispatch") { _ in .error(code: 4018, message: "not a quick/plugin/bundle/skill command: usage") }
        let session = try await openChat(gateway)

        await #expect(throws: RPCError(code: 5030, message: "slash worker timed out")) {
            _ = try await session.runSlash("/usage")
        }
    }

    // MARK: Plain RPCs

    /// Desktop runs these as dedicated RPCs, never through `slash.exec`
    /// (`desktop-slash-commands.ts:259-313`,`use-prompt-actions/slash.ts:618-865`).
    @Test func compressSaveStatusAndBackgroundAreRPCs() async throws {
        let gateway = ScriptedGateway()
        // `_compress_live` (`methods_session.py:2097-2138`), summary per `manual_compression_feedback.py:52-96`.
        gateway.on("session.compress", result: [
            "status": "compressed", "removed": 12, "before_messages": 20, "after_messages": 8,
            "before_tokens": 40000, "after_tokens": 9000,
            "summary": ["noop": false, "aborted": false, "refused_would_grow": false, "fallback_used": false,
                        "headline": "Compressed: 20 → 8 messages",
                        "token_line": "Approx request size: ~40,000 → ~9,000 tokens", "note": nil],
            "usage": [:], "info": ["model": "test-model", "title": "Release prep"], "messages": [],
        ])
        gateway.on("session.save", result: ["file": "/srv/hermes/sessions/saved/hermes_conversation_20261006_101500.json"])
        gateway.on("session.status", result: ["output": "Model: test-model\nTokens: 9,000"])
        gateway.on("prompt.background", result: ["task_id": "bg_42"])
        let session = try await openChat(gateway)

        #expect(try await session.runSlash("/compact the API design") ==
                .output("Compressed: 20 → 8 messages\nApprox request size: ~40,000 → ~9,000 tokens"))
        #expect(gateway.params("session.compress") == [["session_id": "sid-1", "focus_topic": "the API design"]])
        #expect(session.title == "Release prep")

        #expect(try await session.runSlash("/save") ==
                .output("Saved transcript to /srv/hermes/sessions/saved/hermes_conversation_20261006_101500.json"))
        #expect(try await session.runSlash("/status") == .output("Model: test-model\nTokens: 9,000"))

        #expect(try await session.runSlash("/bg summarise the logs") == .handled)
        #expect(gateway.params("prompt.background") == [["session_id": "sid-1", "text": "summarise the logs"]])
        gateway.transport.sendEvent("background.complete", payload: ["task_id": "bg_42", "text": "3 errors"])
        #expect(await eventually { session.transcript.items.last?.sideQuestion?.answer == "3 errors" })

        #expect(gateway.params("slash.exec").isEmpty && gateway.params("command.dispatch").isEmpty)
    }

    /// Another compression holds the lock (`methods_session.py:2160-2163`).
    @Test func aCompressionAlreadyRunningIsReported() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.compress", result: ["compressed": false, "lock_held": true,
                                                "message": "Compression already running in another window."])
        let session = try await openChat(gateway)

        #expect(try await session.compress() == "Compression already running in another window.")
    }

    @Test func btwAndTitleRunInThePackage() async throws {
        let gateway = ScriptedGateway()
        gateway.on("prompt.btw", result: ["task_id": "btw_1"])
        gateway.on("session.title") { params in .result(["title": params["title"] ?? "", "pending": false]) }
        let session = try await openChat(gateway)

        #expect(try await session.runSlash("/btw is CI green?") == .handled)
        #expect(gateway.params("prompt.btw") == [["session_id": "sid-1", "text": "is CI green?"]])
        #expect(try await session.runSlash("/title Release prep") == .output("Renamed to Release prep."))
        #expect(gateway.params("session.title") == [["session_id": "sid-1", "title": "Release prep"]])
        #expect(session.title == "Release prep")
    }

    /// Desktop's `/stop` (`use-prompt-actions/slash.ts:525-570`): `session.interrupt`, then
    /// `process.stop {}` (`methods_tools.py:265`), both results in one note.
    @Test func stopInterruptsAndStopsBackgroundProcesses() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.interrupt", result: ["status": "interrupted", "interrupted": true])
        gateway.on("process.stop", result: ["killed": 2])
        let session = try await openChat(gateway)

        let text = "Stopped the active turn.\nStopped 2 background processes."
        #expect(try await session.runSlash("/stop") == .output(text))
        #expect(gateway.params("session.interrupt") == [["session_id": "sid-1"]])
        #expect(gateway.params("process.stop") == [[:]])
        #expect(session.transcript.items.last?.text == text)

        gateway.on("process.stop", result: ["killed": 0])
        #expect(try await session.runSlash("/stop") == .output("Stopped the active turn.\nNo background processes to stop."))
    }

    /// A failure of either half is its own line; the other half still runs.
    @Test func stopReportsEachFailure() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.interrupt") { _ in .error(code: 4001, message: "session not found") }
        gateway.on("process.stop") { _ in .error(code: 5010, message: "registry unavailable") }
        let session = try await openChat(gateway)

        guard case .output(let text) = try await session.runSlash("/stop") else {
            Issue.record("expected a note")
            return
        }
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("Could not stop the active turn: ") == true)
        #expect(lines.last?.hasPrefix("Could not stop background processes: ") == true)
        #expect(gateway.params("process.stop").count == 1)
    }

    /// A skill's prompt clears this session's stranded images first, as `send` does:
    /// a turn takes every queued image (`prompt_turn.py:147-149`).
    @Test func aSkillPromptClearsStrandedImagesFirst() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec") { _ in .error(code: 4018, message: "skill command: use command.dispatch for /standup") }
        gateway.on("command.dispatch", result: ["type": "skill", "name": "standup", "message": "[SKILL: standup]"])
        gateway.on("image.detach", result: ["detached": true, "count": 0])
        let session = try await openChat(gateway)
        let connection = try #require(session.connection)
        connection.strand([StrandedImage(sessionID: "sid-1", profile: nil, path: "/p/stuck.png")])

        #expect(try await session.runSlash("/standup") == .submitted(display: "/standup"))

        let methods = gateway.log.all.compactMap { $0["method"]?.stringValue }
        let detach = try #require(methods.firstIndex(of: "image.detach"))
        let submit = try #require(methods.firstIndex(of: "prompt.submit"))
        #expect(detach < submit)
        #expect(session.strandedImagePaths.isEmpty)
    }

    /// Quick-command alias targets may already start with `/` (`cli.py:1255-1257`);
    /// Desktop strips every leading slash (`apps/shared/src/slash.ts:36`).
    @Test func anAliasTargetWithASlashRuns() async throws {
        let gateway = ScriptedGateway()
        gateway.on("slash.exec") { params in
            params["command"] == "deploy" ? .result(["type": "alias", "target": "/usage"])
                : .result(["output": "Tokens: 5"])
        }
        let session = try await openChat(gateway)

        #expect(try await session.runSlash("/deploy") == .output("Tokens: 5"))
        #expect(gateway.params("slash.exec").last == ["session_id": "sid-1", "command": "usage"])
        #expect(SlashCommand.parse("//usage now") == ("usage", "now"))
    }
}
