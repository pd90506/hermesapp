import Foundation
import HermesKit
import HermesProtocol
import Testing

@testable import HermesBridge

/// The composer's draft and slash list, as the Mac's composer keeps them: `setDraft`
/// refreshes the suggestions (a gateway lookup waits 60 ms for the next keystroke),
/// the `composer` snapshot carries the rows, and `send` runs a slash command through
/// the composer (`submitSlash`), its client actions included.
/// A catalog with `/help` and `/model`, as `commands.catalog` sends them.
private let slashCatalog: JSONValue = [
    "pairs": [], "sub": [:], "canon": [:], "commands": [:],
    "categories": [["name": "Built-in commands", "pairs": [["/help", "Show the commands"],
                                                              ["/model", "Pick the model"]]]],
    "skills": [:], "skill_count": 0, "warning": "",
]

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BridgeSlashTests {
    private func openedBridge(outbox: Outbox, server: BridgeServer) async throws -> Bridge {
        server.on("commands.catalog") { _ in slashCatalog }
        server.on("complete.slash") { _ in ["items": [["text": "help", "display": "help",
                                                       "meta": "Show the commands"]], "replace_from": 1] }
        let bridge = try await Bridge.connected(server, outbox: outbox)
        try await Bridge.openedChat(bridge, outbox: outbox, server: server)
        return bridge
    }

    @Test func theDraftFollowsAndItsSuggestionsCarryAsRows() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server)

        try await bridge.receive(#"{"id":"d1","method":"setDraft","params":{"text":"/he"}}"#)
        #expect(await eventually {
            let composer = outbox.last("composer")
            return (composer?["draft"] as? String) == "/he" && (composer?["slashIsOpen"] as? Bool) == true
        })
        let composer = try #require(outbox.last("composer"))
        let rows = try #require(composer["slashRows"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["text"] as? String == "/help")
        #expect(rows[0]["display"] as? String == "help")
        #expect(rows[0]["meta"] as? String == "Show the commands")
        // A query's rows group by the item's kind, as Desktop groups them.
        #expect(rows[0]["header"] as? String == "Commands")
        #expect(rows[0]["isSelected"] as? Bool == true)

        // The complete.slash lookup went out for the draft as typed.
        let completion = try #require(server.log.requests("complete.slash").last)
        #expect(completion["params"]?["text"]?.stringValue == "/he")

        // Accepting a row puts it in the draft, with a trailing space, and closes the list.
        try await bridge.receive(#"{"id":"d2","method":"acceptSlashRow","params":{"id":"/help"}}"#)
        #expect(await eventually {
            let composer = outbox.last("composer")
            return (composer?["draft"] as? String) == "/help " && (composer?["slashIsOpen"] as? Bool) == false
        })

        // A plain draft shows no list.
        try await bridge.receive(#"{"id":"d3","method":"setDraft","params":{"text":"hello"}}"#)
        #expect(await eventually {
            (outbox.last("composer")?["slashIsOpen"] as? Bool) == false
        })
    }

    @Test func theKeysTheListTakesAreAnswered() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server)
        try await bridge.receive(#"{"id":"d1","method":"setDraft","params":{"text":"/he"}}"#)
        #expect(await eventually { (outbox.last("composer")?["slashIsOpen"] as? Bool) == true })

        // Down moves the highlight, Escape dismisses for this draft, and a second
        // plain Escape comes back unused.
        try await bridge.receive(#"{"id":"k1","method":"slashKey","params":{"key":"down"}}"#)
        try await bridge.receive(#"{"id":"k2","method":"slashKey","params":{"key":"escape"}}"#)
        let closed = await eventually {
            let composer = outbox.last("composer")
            return (composer?["slashIsOpen"] as? Bool) == false && composer?["slashNotice"] == nil
        }
        #expect(closed)
        try await bridge.receive(#"{"id":"k3","method":"slashKey","params":{"key":"escape"}}"#)
        let reply = try #require(outbox.last)
        // No list, no notice: the key is the text field's own.
        #expect((reply["result"] as? Bool) == false)
    }

    @Test func sendingASlashCommandRunsItThroughTheComposer() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        // A second create for /new's own chat.
        let counter = ScriptedCounter()
        server.on("session.create") { _ in
            let n = counter.increment() + 1
            return BridgeServer.created(sid: "rt-\(n)", key: "stored-\(n)")
        }
        let bridge = try await Bridge.connected(server, outbox: outbox)
        try await bridge.receive(#"{"id":"o1","method":"newChat","params":{"profile":"coder"}}"#)
        // A prompt first, so the chat is one /new leaves behind for a fresh one.
        try await bridge.receive(#"{"id":"s0","method":"send","params":{"text":"hi there"}}"#)
        let prompt = try #require(server.log.requests("prompt.submit").last)
        #expect(prompt["params"]?["text"]?.stringValue == "hi there")

        // `/model` with no argument asks for the picker rather than sending anything.
        try await bridge.receive(#"{"id":"s1","method":"send","params":{"text":"/model"}}"#)
        #expect(await eventually { (outbox.last("composer")?["isModelPickerRequested"] as? Bool) == true })
        // Nothing was sent to the gateway as a prompt.
        // The /model send sent nothing.
        #expect(server.log.requests("prompt.submit").count == 1)
        try await bridge.receive(#"{"id":"d1","method":"setModelPickerRequested","params":{"shown":false}}"#)
        #expect(await eventually { (outbox.last("composer")?["isModelPickerRequested"] as? Bool) == false })

        // The draft a slash send leaves is the composer's own, not the app's text: the
        // app reads it back from the snapshot instead of clearing its field.
        try await bridge.receive(#"{"id":"s2","method":"send","params":{"text":"/new"}}"#)
        #expect(await eventually {
            let chat = outbox.last("chat")
            return (chat?["sessionID"] as? String) == "rt-2"
        })
        let chat = try #require(outbox.last("chat"))
        #expect(chat["storedSessionID"] as? String == "stored-2")
        // /new on a prompted chat made another one, and the bridge followed it.
        let composer = try #require(outbox.last("composer"))
        #expect((composer["draft"] as? String ?? "").isEmpty)
    }

    @Test func reopenKeepsTheComposerItAlreadyHas() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server)
        try await bridge.receive(#"{"id":"d1","method":"setDraft","params":{"text":"still typing"}}"#)
        #expect(await eventually { outbox.last("composer")?["draft"] as? String == "still typing" })
        // Opening the same unsent chat again (the Mac's New chat while it is showing):
        // the composer is kept, draft and all, not made afresh.
        try await bridge.receive(#"{"id":"o2","method":"newChat","params":{"profile":"coder"}}"#)
        let composer = try #require(outbox.last("composer"))
        #expect(composer["draft"] as? String == "still typing")
    }
}

/// A thread-safe counter for scripted answers that vary.
final class ScriptedCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value - 1
    }
}
