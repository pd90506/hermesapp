import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// The app against what the real Hermes handlers return (`RealSlashResponses`, captured
/// from `tui_gateway.server.handle_request`), not against fixtures shaped like the app's
/// assumptions. A contract drift in `commands.catalog` or `complete.slash` fails here.
func realSlashJSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// A gateway answering `commands.catalog` and `complete.slash` (`/c`, `/com`, `/comp`,
/// `/compress`, `/zzz`) with the captured responses; other lookups are left unanswered.
func realSlashGateway() throws -> ScriptedGateway {
    let gateway = ScriptedGateway()
    gateway.on("commands.catalog", result: try realSlashJSON(RealSlashResponses.catalog))
    let answers: [String: JSONValue] = [
        "/c": try realSlashJSON(RealSlashResponses.slashC), "/com": try realSlashJSON(RealSlashResponses.slashCom),
        "/comp": try realSlashJSON(RealSlashResponses.slashComp),
        "/compress": try realSlashJSON(RealSlashResponses.slashCompress),
        "/zzz": try realSlashJSON(RealSlashResponses.slashNoMatch),
    ]
    gateway.on("complete.slash") { params in
        answers[params["text"]?.stringValue ?? ""].map { .result($0) }
    }
    return gateway
}

private func catalog() throws -> SlashCatalog {
    SlashCatalog(try realSlashJSON(RealSlashResponses.catalog).decode(CommandsCatalogResult.self))
}

private func completions(_ captured: String, for text: String) throws -> SlashCompletions {
    SlashCompletions(try realSlashJSON(captured).decode(CompleteSlashResult.self), text: text)
}

@Suite struct RealSlashContractTests {
    /// Every field the app reads decodes from the real catalog.
    @Test func theRealCatalogDecodes() throws {
        let raw = try realSlashJSON(RealSlashResponses.catalog).decode(CommandsCatalogResult.self)
        #expect((raw.pairs?.count ?? 0) > 50)
        #expect(raw.canon?["/compact"] == "/compress")
        #expect(raw.commands?["/compress"]?.argumentMode == "text")
        #expect(raw.skills?["/competitor-news-monitor"]?.origin == "local")
        #expect(raw.skillCount == 2)
        #expect(raw.categories?.first?.name == "Session")

        let catalog = try catalog()
        #expect(catalog.command(named: "/compress")?.category == "Session")
        #expect(catalog.command(named: "/competitor-news-monitor")?.kind == .skill)
        #expect(catalog.command(named: "/competitor-news-monitor")?.category == "Skills")
        #expect(catalog.canonicalName("/compact") == "/compress")
        #expect(catalog.argumentMode(for: "/compress") == "text")
    }

    /// Bare `/` lists the catalog: registry sections, skills last.
    @Test func bareSlashListsTheCatalog() throws {
        let rows = try catalog().suggestions(for: "/")
        #expect(rows.count > 50)
        #expect(rows.contains { $0.text == "/compress" })
        #expect(!rows.contains { $0.text == "/compact" })  // an alias
        #expect(rows.suffix(2).map(\.text) == ["/codebase-inspection", "/competitor-news-monitor"])
        #expect(rows.allSatisfy { $0.text.hasPrefix("/") })
    }

    /// Command-stage items come without the slash (`compress`), an exact match with a
    /// trailing space (`compress `); the app's items are `/name`.
    @Test func commandItemsBecomeSlashNames() throws {
        let com = try completions(RealSlashResponses.slashCom, for: "/com")
        #expect(com.replaceFrom == 1)
        #expect(com.items.contains { $0.text == "/compress" && $0.display == "/compress" })
        #expect(com.items.allSatisfy { $0.text.hasPrefix("/") && !$0.text.hasPrefix("//") && $0.text == $0.text.trimmingCharacters(in: .whitespaces) })
        #expect(com.applying(com.items[0]) == com.items[0].text)

        let exact = try completions(RealSlashResponses.slashCompress, for: "/compress")
        #expect(exact.items.first?.text == "/compress")
        let raw = try realSlashJSON(RealSlashResponses.slashCompress).decode(CompleteSlashResult.self)
        #expect(raw.items.first?.text == "compress ")  // what the gateway sends

        let argument = try completions(RealSlashResponses.slashPersonalityArgument, for: "/personality ")
        #expect(argument.replaceFrom == 13)
        #expect(argument.applying(argument.items[1]) == "/personality helpful")
    }

    /// `/com` lists the matching commands, then the matching skill, as Desktop groups
    /// them; aliases (`/compact`, `/ctx`) only when typed in full.
    @Test func prefixesListCommandsThenSkills() throws {
        let catalog = try catalog()
        let com = catalog.suggestions(for: "/com", completions: try completions(RealSlashResponses.slashCom, for: "/com"))
        #expect(com.first?.text == "/compress")
        #expect(com.contains { $0.text == "/context" })
        #expect(!com.contains { $0.text == "/compact" || $0.text == "/ctx" })
        #expect(com.last?.text == "/competitor-news-monitor")
        #expect(com.last?.category == "Skills")
        #expect(com.dropLast().allSatisfy { $0.category == "Commands" })

        for (captured, text) in [(RealSlashResponses.slashC, "/c"), (RealSlashResponses.slashComp, "/comp")] {
            let rows = catalog.suggestions(for: text, completions: try completions(captured, for: text))
            #expect(rows.contains { $0.text == "/compress" }, "\(text)")
        }
        let compact = catalog.suggestions(for: "/compact",
                                          completions: try completions(RealSlashResponses.slashCompact, for: "/compact"))
        #expect(compact.map(\.text) == ["/compact"])
        let none = catalog.suggestions(for: "/zzz", completions: try completions(RealSlashResponses.slashNoMatch, for: "/zzz"))
        #expect(none.isEmpty)
    }
}

/// The composer end to end, the gateway answering with the captured responses.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RealSlashComposerTests {
    private let connections = ConnectionKeeper()

    private func composer(_ gateway: ScriptedGateway) async throws -> ChatComposer {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return ChatComposer(session: try await connection.newSession())
    }

    /// Panda's report: typing `/com` showed no list at all.
    @Test func typingAPrefixOpensTheList() async throws {
        let composer = try await composer(try realSlashGateway())
        await composer.loadSlashCommands()
        for text in ["/", "/c", "/com", "/comp"] {
            composer.draft = text
            await composer.updateSlashSuggestions()
            #expect(composer.slashIsOpen, "\(text)")
            #expect(composer.slashSuggestions.contains { $0.text == "/compress" }, "\(text)")
        }
        composer.draft = "/com"
        await composer.updateSlashSuggestions()
        // Return takes the highlight (`/compress` extends `/com`), with Desktop's space.
        #expect(composer.acceptSlashSuggestionFromKey(isTab: false))
        #expect(composer.draft == "/compress ")
        await composer.updateSlashSuggestions()
        #expect(!composer.slashIsOpen)  // `/compress` takes free text

        // A fully typed command: the gateway's `compress ` row is `/compress`.
        composer.draft = "/compress"
        await composer.updateSlashSuggestions()
        #expect(composer.slashSuggestions.first?.text == "/compress")
    }
}
