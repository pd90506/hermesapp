import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// Desktop's own cases for `implicitSlashAcceptIndex` (`composer-utils.test.ts:114-155`),
/// with the slash the composer text keeps.
@Suite struct SlashAcceptRuleTests {
    private let rows = ["/compress", "/review", "/resume"]

    private func pick(_ typed: String, _ texts: [String], _ active: Int, _ explicit: Bool) -> Int? {
        SlashSuggestion.implicitAcceptIndex(typed: typed, texts: texts, active: active, explicit: explicit)
    }

    @Test func desktopCases() {
        #expect(pick("/com", rows, 0, false) == 0)  // a prefix of the highlight
        #expect(pick("/review", rows, 0, false) == 1)  // fully typed beats the highlight
        #expect(pick("/review", ["/compress", "/resume"], 0, false) == nil)  // no row extends it
        #expect(pick("/rev", rows, 0, false) == 1)  // the only row that extends it
        #expect(pick("/review", rows, 0, true) == 0)  // an arrowed pick wins
        #expect(pick("/", rows, 1, true) == 1)
        #expect(pick("/", rows, 0, false) == nil)
        #expect(pick("/personality alic", ["/personality alice", "/personality none"], 0, false) == 0)
    }

    @Test func caseAndTrailingSpaceDoNotMatter() {
        #expect(pick("/STOP ", ["/save", "/stop"], 0, false) == 1)
        #expect(pick("/s", ["/save", "/stop"], 0, false) == 0)
        #expect(pick("/stop", [], 0, true) == nil)
    }
}

@Suite struct SlashListTests {
    private func catalog() throws -> SlashCatalog {
        SlashCatalog(try composerSlashCatalog.decode(CommandsCatalogResult.self))
    }

    /// The rows the view draws come from one snapshot: headers where the category
    /// changes, the highlight, and ids unique even for a text the gateway repeated
    /// (`hermes_cli/commands_completion.py:448-466` does not remove duplicates).
    @Test func rowsAreOneSnapshotWithUniqueIDs() {
        func suggestion(_ text: String, _ category: String) -> SlashSuggestion {
            SlashSuggestion(item: SlashCompletionItem(text: text), category: category)
        }
        let rows = SlashRow.rows([suggestion("/deploy", "Skills"), suggestion("/deploy", "Skills"),
                                  suggestion("/deploy#2", "Skills"), suggestion("/save", "Session"),
                                  suggestion("/deploy", "Session")],
                                 selection: 3)
        #expect(rows.map(\.id) == ["/deploy", "/deploy#2", "/deploy#2#2", "/save", "/deploy#3"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.map(\.header) == ["Skills", nil, nil, "Session", nil])
        #expect(rows.map(\.isSelected) == [false, false, false, true, false])
        #expect(SlashRow.rows([], selection: 0).isEmpty)
        #expect(SlashRow.rows([suggestion("/stop", "Session")], selection: 4).map(\.isSelected) == [false])
    }

    /// Bare `/`: refused commands are left out, a command narrowed to some
    /// subcommands stays (`desktop-slash-commands.ts:749`).
    @Test func browsingLeavesOutRefusedCommands() throws {
        let catalog = try catalog()
        let names = catalog.suggestions(for: "/").map(\.item.text)
        #expect(!names.contains("/voice"))
        #expect(names.contains("/skills"))
        #expect(names.first == "/new")
        #expect(!catalog.helpText.contains("/voice"))
        #expect(catalog.helpText.contains("/compress — Compress this conversation context"))
    }

    /// An alias shows only when typed in full (`use-slash-completions.ts:239-257`).
    @Test func aliasesOnlyWhenTypedExactly() throws {
        let catalog = try catalog()
        let browsing = SlashCompletions(CompleteSlashResult(items: [SlashCompletionItem(text: "/compact"),
                                                                    SlashCompletionItem(text: "/compress")]),
                                        text: "/comp")
        #expect(catalog.suggestions(for: "/comp", completions: browsing).map(\.item.text) == ["/compress"])
        let exact = SlashCompletions(CompleteSlashResult(items: [SlashCompletionItem(text: "/compact")]), text: "/compact")
        #expect(catalog.suggestions(for: "/compact", completions: exact).map(\.item.text) == ["/compact"])
    }

    /// Argument rows replace from the server's `replace_from`, not the last space,
    /// and keep to a command's `desktop_subcommands` (`desktop-slash-commands.ts:595-636`).
    @Test func argumentRowsFollowReplaceFromAndTheSubcommandGate() throws {
        let catalog = try catalog()
        let handoff = SlashCompletions(CompleteSlashResult(items: [SlashCompletionItem(text: "telegram group")],
                                                           replaceFrom: 9),
                                       text: "/handoff tele gr")
        #expect(catalog.suggestions(for: "/handoff tele gr", completions: handoff).map(\.text) ==
                ["/handoff telegram group"])

        let skills = SlashCompletions(CompleteSlashResult(items: [SlashCompletionItem(text: "pending"),
                                                                  SlashCompletionItem(text: "install")],
                                                          replaceFrom: 8),
                                      text: "/skills ")
        #expect(catalog.suggestions(for: "/skills ", completions: skills).map(\.text) == ["/skills pending"])
        let value = SlashCompletions(CompleteSlashResult(items: [SlashCompletionItem(text: "abc")], replaceFrom: 16),
                                     text: "/skills install a")
        #expect(catalog.suggestions(for: "/skills install a", completions: value).isEmpty)
    }

    /// Desktop's `UNAVAILABLE_MESSAGE` wording, for the canonical name
    /// (`desktop-slash-commands.ts:505-513,775-792`).
    @Test func refusalsUseDesktopsWording() throws {
        let catalog = SlashCatalog(try JSONValue.object([
            "pairs": [["/reload", "Reload"], ["/sethome", "Set home"], ["/plugins", "Plugins"], ["/debug", "Debug"]],
            "sub": [:], "canon": ["/rl": "/reload"],
            "commands": ["/reload": ["desktop": "terminal"], "/sethome": ["desktop": "messaging"],
                         "/plugins": ["desktop": "settings"], "/debug": ["desktop": "advanced"]],
            "categories": [], "skills": [:], "skill_count": 0, "warning": "",
        ]).decode(CommandsCatalogResult.self))
        #expect(catalog.refusal(for: "rl", argument: "") == "/reload is only available in the terminal interface.")
        #expect(catalog.refusal(for: "/sethome", argument: "") == "/sethome is only used from messaging platforms.")
        #expect(catalog.refusal(for: "/plugins", argument: "x") == "/plugins is managed from the Hermes Desktop sidebar.")
        #expect(catalog.refusal(for: "/debug", argument: "") ==
                "/debug is not shown in the slash palette. Use the relevant Hermes Desktop control or the terminal "
                + "interface instead.")
    }

    /// Past the command name only `options` and `mixed` commands keep a list
    /// (`use-composer-trigger.ts:173-184`).
    @Test func onlyOptionAndMixedArgumentsAreListed() throws {
        let catalog = try catalog()
        #expect(catalog.listsArguments("/personality "))
        #expect(catalog.listsArguments("/goal s"))
        #expect(catalog.listsArguments("/compr"))
        #expect(!catalog.listsArguments("/compress keep the plan"))
        #expect(!catalog.listsArguments("/compact keep the plan"))
        #expect(!catalog.listsArguments("/stop "))
        #expect(catalog.isFreeTextArgument("/goal s"))
        #expect(!catalog.isFreeTextArgument("/personality a"))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerSlashTests {
    private let connections = ConnectionKeeper()

    private func openChat(_ gateway: ScriptedGateway) async throws -> ChatSession {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return try await connection.newSession()
    }

    /// A click acts on the row drawn: found by its id where it is now, even after
    /// the list was replaced; a row no longer listed does nothing.
    @Test func clickingARowAcceptsThatRow() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { params in
            switch params["text"]?.stringValue {
            case "/s"?: return .result(["items": [["text": "/save"], ["text": "/stop"], ["text": "/save"]],
                                        "replace_from": 1])
            case "/st"?: return .result(["items": [["text": "/stop"]], "replace_from": 1])
            default: return nil
            }
        }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()

        composer.draft = "/s"
        await composer.updateSlashSuggestions()
        #expect(composer.slashRows.map(\.id) == ["/save", "/stop", "/save#2"])
        let drawn = composer.slashRows
        // The list is replaced before the click lands: `/stop` moved to row 0.
        composer.draft = "/st"
        await composer.updateSlashSuggestions()
        composer.acceptSlashRow(id: drawn[0].id)  // `/save`, gone now
        #expect(composer.draft == "/st")
        #expect(composer.slashIsOpen)
        composer.acceptSlashRow(id: drawn[1].id)  // `/stop`
        #expect(composer.draft == "/stop ")
        #expect(!composer.slashIsOpen)
        #expect(composer.slashRows.isEmpty)
    }

    /// One `complete.slash` per query, none for prose after a `text` command or
    /// after a command that takes nothing (Desktop caches per query, `use-slash-completions.ts:218`).
    @Test func asksTheGatewayOnlyWhenDesktopWould() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { params in
            params["text"]?.stringValue?.lowercased() == "/sa"
                ? .result(["items": [["text": "/save"]], "replace_from": 1])
                : .result(["items": [["text": "/compress"]], "replace_from": 1])
        }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()

        composer.draft = "/compress keep the migration plan"
        #expect(!composer.slashUpdateNeedsRequest)
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)

        composer.draft = "/co"
        #expect(composer.slashUpdateNeedsRequest)
        await composer.updateSlashSuggestions()
        #expect(!composer.slashUpdateNeedsRequest)
        composer.draft = "/c"
        await composer.updateSlashSuggestions()
        composer.draft = "/CO"
        await composer.updateSlashSuggestions()
        #expect(composer.slashSuggestions.map(\.item.text) == ["/compress"])
        #expect(gateway.params("complete.slash").compactMap { $0["text"]?.stringValue } == ["/co", "/c"])

        // A command that takes nothing: accepted with a space, then no list.
        composer.draft = "/sa"
        await composer.updateSlashSuggestions()
        #expect(composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/save ")
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)
        #expect(gateway.params("complete.slash").count == 3)
    }

    /// A catalog that takes its time (a skills scan) does not hold up the model picker.
    @Test func catalogAndModelOptionsLoadSideBySide() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog") { _ in nil }
        // `model.options` (`hermes_cli/inventory.py:165`); `config.get reasoning` (`methods_config.py:206-224`).
        gateway.on("model.options", result: ["providers": [["slug": "anthropic", "name": "Anthropic",
                                                            "models": ["claude-opus-5-5"]]],
                                             "model": "claude-opus-5-5", "provider": "anthropic"])
        gateway.on("config.get", result: ["value": "high", "display": "show"])
        let composer = ChatComposer(session: try await openChat(gateway))

        let loading = Task { await composer.loadCommandsAndOptions() }
        #expect(await eventually { composer.catalog != nil })
        #expect(gateway.params("commands.catalog").count == 1)
        gateway.transport.respond(to: gateway.log.requests("commands.catalog")[0], result: composerSlashCatalog)
        await loading.value
        composer.draft = "/"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)
    }

    /// Desktop's client actions run in the composer (`use-prompt-actions/slash.ts:518-1135`);
    /// nothing goes out as a prompt.
    @Test func clientActionsRunInTheComposer() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        let session = try await openChat(gateway)
        let composer = ChatComposer(session: session)
        await composer.loadSlashCommands()

        func run(_ text: String) async -> String? {
            composer.draft = text
            _ = await composer.submitSlash()
            return session.transcript.items.last?.text
        }
        #expect(await run("/help")?.contains("/compress — Compress this conversation context") == true)
        #expect(await run("/help")?.contains("/voice") == false)
        #expect(await run("/model gpt-9") == "Model gpt-9 is not available in this chat.")
        #expect(await run("/profile")?.hasPrefix("/profile is not available in this app yet.") == true)
        #expect(await run("/reasoning")?.hasPrefix("Reasoning effort: ") == true)
        #expect(await run("/resume 20261008_abc")?.hasPrefix("Choose a chat from History.") == true)
        #expect(await run("/yolo") == "/yolo is not available in this app yet.")

        #expect(!composer.isModelPickerRequested)
        _ = await run("/model")
        #expect(composer.isModelPickerRequested)

        let connection = try #require(session.connection)
        _ = await run("/reset")
        #expect(gateway.params("session.create").count == 2)
        #expect(connection.activeSession !== session)
        #expect(gateway.params("prompt.submit").isEmpty)
    }

    /// A running `/compress` shows in `isCompressing` (Desktop's notice is for a
    /// compaction only, `slash.ts:703-709`); a second one, or its alias, while it
    /// runs is dropped (:696-700). Other commands show nothing.
    @Test func aRunningCompressShowsAndASecondIsDropped() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("session.compress") { _ in nil }
        gateway.on("session.save") { _ in nil }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()

        composer.draft = "/save"
        let saving = Task { await composer.submitSlash() }
        #expect(await eventually { gateway.params("session.save").count == 1 })
        #expect(!composer.isCompressing)

        composer.draft = "/compress"
        let compressing = Task { await composer.submitSlash() }
        #expect(await eventually { gateway.params("session.compress").count == 1 })
        #expect(composer.isCompressing)
        composer.draft = "/compact older turns"
        #expect(await composer.submitSlash() == .handled)
        #expect(composer.draft.isEmpty)
        #expect(gateway.params("session.compress").count == 1)

        gateway.transport.respond(to: gateway.log.requests("session.compress")[0], result: ["status": "ok", "removed": 2])
        _ = await compressing.value
        #expect(!composer.isCompressing)
        gateway.transport.respond(to: gateway.log.requests("session.save")[0], result: ["file": "/tmp/x.json"])
        _ = await saving.value
    }

    /// In a Bot Chat `/new` compacts instead (Desktop rewrites it to `/compact`,
    /// `plugins/hermes-bots/plugin.tsx:771-797`), so it is dropped like a second
    /// `/compress` while one runs, and shows the same row.
    @Test func botChatNewIsCoalescedWithARunningCompress() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("session.compress") { _ in nil }
        let opened = try await openChat(gateway)
        let bot = ChatSession(snapshot: LiveSessionSnapshot(sessionID: "sid-1", messages: [], running: false),
                              title: "Bot Chat", profile: "coder", kind: .botChat, connection: opened.connection)
        let composer = ChatComposer(session: bot)
        await composer.loadSlashCommands()

        composer.draft = "/new"
        let compacting = Task { await composer.submitSlash() }
        #expect(await eventually { gateway.params("session.compress").count == 1 })
        #expect(composer.isCompressing)
        composer.draft = "/compress"
        #expect(await composer.submitSlash() == .handled)
        composer.draft = "/reset"
        #expect(await composer.submitSlash() == .handled)
        #expect(gateway.params("session.compress").count == 1)

        gateway.transport.respond(to: gateway.log.requests("session.compress")[0], result: ["status": "ok", "removed": 1])
        _ = await compacting.value
        #expect(!composer.isCompressing)
    }

    /// Tab with no rows while a lookup is due or in flight is swallowed (Desktop
    /// `index.tsx:800-809`); not once the answer is in, or the lookup failed.
    @Test func tabIsSwallowedOnlyWhileALookupIsPending() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("complete.slash") { params in
            switch params["text"]?.stringValue {
            case "/zz"?: return .result(["items": [], "replace_from": 1])
            case "/qq"?: return .error(code: 5000, message: "completion failed")
            default: return nil
            }
        }
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadSlashCommands()

        composer.draft = "/zz"
        #expect(composer.swallowsSlashTab)
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)
        #expect(!composer.swallowsSlashTab)

        composer.draft = "/qq"
        await composer.updateSlashSuggestions()
        #expect(!composer.swallowsSlashTab)

        composer.draft = "/compress keep the plan"  // prose: no lookup
        #expect(!composer.swallowsSlashTab)
        composer.draft = "hello"
        #expect(!composer.swallowsSlashTab)
    }

    /// `/model <name>` switches this chat's model when the catalog has it.
    @Test func modelWithANameSwitchesTheSession() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: composerSlashCatalog)
        gateway.on("model.options", result: ["providers": [["slug": "anthropic", "name": "Anthropic",
                                                            "models": ["claude-opus-5-5", "claude-haiku-4-5"]]],
                                             "model": "claude-opus-5-5", "provider": "anthropic"])
        gateway.on("config.get", result: ["value": "high", "display": "show"])
        // `config.set model` (`methods_config_set.py:161-163`).
        gateway.on("config.set", result: ["key": "model", "value": "claude-haiku-4-5", "warning": "",
                                          "confirm_required": false, "confirm_message": "", "scope": "session"])
        let composer = ChatComposer(session: try await openChat(gateway))
        await composer.loadCommandsAndOptions()

        composer.draft = "/model claude-haiku-4-5"
        _ = await composer.submitSlash()
        #expect(gateway.params("config.set").first?["key"] == "model")
        #expect(gateway.params("config.set").first?["value"]?.stringValue?.hasPrefix("claude-haiku-4-5") == true)
        #expect(composer.error == nil)
    }
}
