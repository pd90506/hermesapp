import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// Rows `commands.catalog` doesn't list (skill bundles, the gateway's extras), against the
/// real handlers' responses (`RealSlashBundleResponses`, same catalog as `RealSlashResponses`).
/// Desktop lists them (`isDesktopSlashExtensionCommand`, `desktop-slash-commands.ts:672-680,752-753`);
/// commands the catalog marks hidden or GUI-unavailable stay out.
@Suite struct RealSlashExtensionRowsTests {
    private func catalog() throws -> SlashCatalog {
        SlashCatalog(try realSlashJSON(RealSlashResponses.catalog).decode(CommandsCatalogResult.self))
    }

    private func rows(_ captured: String, for text: String) throws -> [SlashSuggestion] {
        let result = try realSlashJSON(captured).decode(CompleteSlashResult.self)
        return try catalog().suggestions(for: text, completions: SlashCompletions(result, text: text))
    }

    @Test func aSkillBundleListsUnderSkills() throws {
        let rows = try rows(RealSlashBundleResponses.slashRese, for: "/rese")
        #expect(rows.last?.text == "/research-pack")
        #expect(rows.last?.category == "Skills")
        #expect(rows.contains { $0.text == "/retry" && $0.category == "Commands" })
        #expect(!rows.contains { $0.text == "/reset" })  // an alias of /new, not typed in full
    }

    /// The gateway sends only `research-pack ` for the bundle typed in full: it lists,
    /// rather than "No matches".
    @Test func aBundleTypedInFullLists() throws {
        let raw = try realSlashJSON(RealSlashBundleResponses.slashResearchPack).decode(CompleteSlashResult.self)
        #expect(raw.items.map(\.text) == ["research-pack "])
        #expect(try rows(RealSlashBundleResponses.slashResearchPack, for: "/research-pack").map(\.text)
            == ["/research-pack"])
    }

    @Test func theGatewaysExtrasList() throws {
        let det = try rows(RealSlashBundleResponses.slashDet, for: "/det")
        #expect(det.map(\.text) == ["/context", "/details"])  // `/ctx` is an alias
        let de = try rows(RealSlashBundleResponses.slashDe, for: "/de")
        #expect(de.contains { $0.text == "/details" && $0.category == "Commands" })
        #expect(de.contains { $0.text == "/density" })
        #expect(de.last?.text == "/codebase-inspection")
    }

    /// `/de` returns `model` (`desktop: hidden`) and GUI-unavailable commands (`quit`,
    /// `statusbar`, `fast`, `voice`, …): none lists, listed in the catalog or not.
    @Test func hiddenAndUnavailableCommandsStayOut() throws {
        let catalog = try catalog()
        #expect(catalog.command(named: "/model") == nil)  // hidden: not in the catalog's list
        let rows = try rows(RealSlashBundleResponses.slashDe, for: "/de")
        for name in ["/model", "/quit", "/exit", "/statusbar", "/fast", "/indicator", "/voice"] {
            #expect(!rows.contains { $0.text == name }, "\(name)")
        }
        for row in rows {
            let entry = catalog.meta[catalog.canonicalName(row.text)]
            #expect(entry?.desktop == nil, "\(row.text) is \(entry?.desktop ?? "")")
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RealSlashExtensionComposerTests {
    private let connections = ConnectionKeeper()

    private func composer(_ gateway: ScriptedGateway) async throws -> ChatComposer {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return ChatComposer(session: try await connection.newSession())
    }

    /// The bundle typed in full: the list opens on it, no notice, and Return takes it.
    @Test func aBundleTypedInFullOpensTheList() async throws {
        let gateway = try realSlashGateway()
        let answer = try realSlashJSON(RealSlashBundleResponses.slashResearchPack)
        gateway.on("complete.slash") { _ in .result(answer) }
        let composer = try await composer(gateway)
        await composer.loadSlashCommands()
        composer.draft = "/research-pack"
        await composer.updateSlashSuggestions()
        #expect(composer.slashIsOpen)
        #expect(composer.slashNotice == nil)
        #expect(composer.handleSlashKey(.accept))
        #expect(composer.draft == "/research-pack ")
    }

    /// A failed catalog is reported on a command name only, as Desktop places its
    /// empty state: not while argument text is typed.
    @Test func aCatalogFailureShowsOnlyOnACommandName() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog") { _ in .error(code: 5000, message: "skills scan failed") }
        let composer = try await composer(gateway)
        await composer.loadSlashCommands()
        composer.draft = "/compress some text"
        await composer.updateSlashSuggestions()
        #expect(composer.slashNotice == nil)
        composer.draft = "/co"
        await composer.updateSlashSuggestions()
        #expect(composer.slashNotice?.hasPrefix("Couldn't load commands: ") == true)
        composer.draft = "/co more"
        await composer.updateSlashSuggestions()
        #expect(composer.slashNotice == nil)
    }

    /// Esc dismisses a showing notice; with nothing shown, no key is taken.
    @Test func escapeDismissesANoticeAndNothingElse() async throws {
        let composer = try await composer(try realSlashGateway())
        await composer.loadSlashCommands()
        composer.draft = "hello"
        await composer.updateSlashSuggestions()
        for key in [SlashListKey.escape, .up, .down, .tab, .accept] { #expect(!composer.handleSlashKey(key)) }

        composer.draft = "/zzz"
        await composer.updateSlashSuggestions()
        #expect(composer.slashNotice == "No matches. Try /help.")
        for key in [SlashListKey.up, .down, .tab, .accept] { #expect(!composer.handleSlashKey(key)) }
        #expect(composer.slashNotice != nil)
        #expect(composer.handleSlashKey(.escape))
        #expect(composer.slashNotice == nil)
        #expect(!composer.handleSlashKey(.escape))  // nothing left: Esc goes on
        await composer.updateSlashSuggestions()
        #expect(composer.slashNotice == nil)  // dismissed for this text
        #expect(composer.draft == "/zzz")
    }
}
