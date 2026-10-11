import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

/// An in-memory gateway for a hosted composer: it answers the connect handshake,
/// `session.create`, `commands.catalog`, `complete.slash` (by text) and `session.save`
/// at once, from fixed tables, so every list change is deterministic. Anything else
/// is left unanswered. Payload shapes follow the package fixtures
/// (`Packages/HermesKit/Tests/HermesKitTests/Support/ScriptedGateway.swift`).
private final class SlashGateway: MessageTransport, GatewayConnector {
    private let pair = AsyncThrowingStream<String, any Error>.makeStream()
    private let catalog: JSONValue
    private let completions: [String: JSONValue]

    init(catalog: JSONValue, completions: [String: JSONValue]) {
        self.catalog = catalog
        self.completions = completions
        yield(["jsonrpc": "2.0", "method": "event",
               "params": ["type": "gateway.ready",
                          "payload": ["skin": [:], "change_events": true, "heartbeat": false,
                                      "replay_epoch": "epoch-1"]]])
    }

    var inbound: AsyncThrowingStream<String, any Error> { pair.stream }
    func makeTransport() async throws -> any MessageTransport { self }
    func connect() async throws {}
    func close() async { pair.continuation.finish() }

    func send(_ text: String) async throws {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            let id = frame["id"], let method = frame["method"]?.stringValue
        else { return }
        let result: JSONValue?
        switch method {
        case "client.capabilities": result = ["server_requests": ["approval", "clarify", "sudo", "secret"]]
        case "session.list": result = ["sessions": []]
        case "profiles.list": result = ["profiles": [], "bot_mode_protocol": true, "install_id": "test"]
        case "session.create":
            result = ["session_id": "sid-1", "stored_session_id": "stored-1", "message_count": 0, "messages": [],
                      "info": ["model": "test-model"]]
        case "commands.catalog": result = catalog
        case "complete.slash":
            result = completions[frame["params"]?["text"]?.stringValue ?? ""] ?? ["items": [], "replace_from": 1]
        case "session.save": result = ["file": "/tmp/x.json"]
        default: result = nil
        }
        if let result { yield(["jsonrpc": "2.0", "id": id, "result": result]) }
    }

    private func yield(_ value: JSONValue) {
        pair.continuation.yield(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self))
    }
}

/// The composer's slash list (`SlashSuggestionList`, as `ComposerView` shows it),
/// hosted in a window and laid out while the list changes underneath it: shrinking
/// and growing as the user types, replaced by lookup answers, holding duplicate
/// texts, and emptied by a lookup with no matches, Esc, a send and a catalog reload.
///
/// Before the fix (`964e5a5`), each row looked up the row before it in the live list
/// by the index it was drawn with (`slashSuggestions[index - 1]`). When the list
/// empties, SwiftUI lays out the rows being removed once more, with their old
/// indices, and the lookup trapped: `crash-slash-215700`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerSlashListTests {
    /// The lookups' commands sit among the first rows, as in a real catalog.
    private static let names = ["/c00", "/save", "/c01", "/c02", "/c03", "/stop", "/deploy", "/goal"]
        + (4..<40).map { String(format: "/c%02d", $0) }

    private static let catalog: JSONValue = {
        let pairs = names.map { JSONValue.array([.string($0), .string("About \($0)")]) }
        var commands: [String: JSONValue] = [:]
        for name in names {
            commands[name] = ["argument_mode": name == "/goal" ? JSONValue.string("mixed") : .null, "desktop": .null]
        }
        return ["pairs": .array(pairs), "sub": [:], "canon": [:], "commands": .object(commands),
                "categories": [["name": "Session", "pairs": .array(Array(pairs.prefix(17)))],
                               ["name": "Configuration", "pairs": .array(Array(pairs.dropFirst(17)))]],
                "skills": [:], "skill_count": 0, "warning": ""]
    }()

    /// `complete.slash` answers. `/d` and `/goal s` repeat a text: the completer
    /// yields built-ins, bundles, skills and plugin commands without removing
    /// duplicates (`hermes_cli/commands_completion.py:448-466`), and the fuzzy merge
    /// only keeps catalog rows from repeating it (`tui_gateway/slash_fuzzy.py:51-55`).
    private static let completions: [String: JSONValue] = [
        "/s": ["items": [["text": "/save"], ["text": "/stop"]], "replace_from": 1],
        "/st": ["items": [["text": "/stop"]], "replace_from": 1],
        "/d": ["items": [["text": "/deploy"], ["text": "/deploy"], ["text": "/c01"], ["text": "/deploy"]],
               "replace_from": 1],
        "/goal s": ["items": [["text": "status"], ["text": "set"], ["text": "status"]], "replace_from": 6],
    ]

    /// `ComposerView`'s arrangement: the list (which shows while `slashIsOpen`) above
    /// the text. `ComposerView` itself needs the app's `AppModel`, which this test
    /// bundle does not compile; the list is the same view.
    private struct Popover: View {
        let composer: ChatComposer
        var body: some View {
            VStack(spacing: 0) {
                SlashSuggestionList(composer: composer)
                Text(composer.draft).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
        }
    }

    private func host(_ composer: ChatComposer) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: .testArea(CGSize(width: 520, height: 520)), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // Owned by the test: closing must not release it a second time.
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Popover(composer: composer)
            .frame(width: 520, height: 520, alignment: .top))
        window.contentView = host
        // Shown, not made key: other suites' windows keep their key state.
        window.orderFront(nil)
        return (window, host)
    }

    /// Lets SwiftUI flush its transactions, lay the rows out and draw, as the app's run loop does.
    private func settle(_ host: NSView) {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        host.layoutSubtreeIfNeeded()
    }

    private func set(_ text: String, on composer: ChatComposer, _ host: NSView) async {
        composer.draft = text
        await composer.updateSlashSuggestions()
        settle(host)
    }

    @Test func theListSurvivesEveryKindOfChange() async throws {
        let gateway = SlashGateway(catalog: Self.catalog, completions: Self.completions)
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration)
        try await connection.connect(using: gateway)
        let composer = ChatComposer(session: try await connection.newSession())
        let (window, host) = host(composer)
        defer { window.close() }
        await composer.loadSlashCommands()

        // Open, then empty it the ways the app does: Esc, a lookup with no matches,
        // a send, a catalog reload.
        await set("/", on: composer, host)
        #expect(composer.slashSuggestions.count == Self.names.count)
        composer.dismissSlashSuggestions()
        settle(host)
        #expect(!composer.slashIsOpen)
        await set("/s", on: composer, host)
        await set("/zz", on: composer, host)
        #expect(!composer.slashIsOpen)
        await set("/", on: composer, host)
        composer.draft = "/save"
        _ = await composer.submitSlash()
        settle(host)
        #expect(!composer.slashIsOpen)
        await set("/", on: composer, host)
        await composer.loadSlashCommands()
        settle(host)
        #expect(composer.slashIsOpen)

        // Shrink and grow as the user types.
        for _ in 0..<2 {
            await set("/s", on: composer, host)
            #expect(composer.slashSuggestions.map(\.item.text) == ["/save", "/stop"])
            await set("/st", on: composer, host)
            #expect(composer.slashSuggestions.map(\.item.text) == ["/stop"])
            await set("/", on: composer, host)
        }

        // Every change between these lists (long, short, one row, repeated texts,
        // none), with the highlight moved first, as arrowing through it does.
        let shapes = ["/", "/s", "/st", "/d", "/goal s", "/zz"]
        for round in 0..<2 {
            for from in shapes {
                for to in shapes where to != from {
                    await set(from, on: composer, host)
                    for _ in 0...round { composer.moveSlashSelection(-1) }
                    settle(host)
                    await set(to, on: composer, host)
                }
            }
        }

        // Several changes with no layout in between, then one.
        composer.draft = "/s"
        await composer.updateSlashSuggestions()
        composer.draft = "/"
        await composer.updateSlashSuggestions()
        composer.draft = "/st"
        await composer.updateSlashSuggestions()
        settle(host)
        #expect(composer.slashSuggestions.map(\.item.text) == ["/stop"])
        #expect(composer.slashRows.map(\.id) == ["/stop"])
        await connection.disconnect()
    }
}
