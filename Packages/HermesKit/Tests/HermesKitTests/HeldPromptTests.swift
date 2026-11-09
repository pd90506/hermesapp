import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// Messages sent while a reply runs wait in the app (`ChatComposer.heldPrompts`): sent
/// once the session is free, taken back, or steered into the running turn.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HeldPromptTests {
    /// `ChatSession.connection` is weak: the test owns the connection.
    private let connections = ConnectionKeeper()

    private func openComposer(_ gateway: ScriptedGateway) async throws -> ChatComposer {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return connection.composer(for: try await connection.newSession())
    }

    /// A composer with a reply running.
    private func composerMidReply(_ gateway: ScriptedGateway) async throws -> ChatComposer {
        let composer = try await openComposer(gateway)
        composer.draft = "long task"
        await composer.submit()
        gateway.transport.sendEvent("message.start")
        #expect(await eventually { composer.session.transcript.isRunning })
        return composer
    }

    @Test func aMessageSentMidReplyWaitsAndGoesOutOnceTheReplyEnds() async throws {
        let gateway = ScriptedGateway()
        let composer = try await composerMidReply(gateway)

        composer.draft = "next"
        await composer.submit()
        #expect(composer.heldPrompts.map(\.text) == ["next"])
        #expect(composer.draft.isEmpty)
        #expect(gateway.params("prompt.submit").count == 1, "not sent to Hermes yet")
        #expect(!composer.session.transcript.items.contains { $0.text == "next" })

        await composer.sendNextHeld()
        #expect(composer.heldPrompts.count == 1, "the reply still runs")

        gateway.transport.sendEvent("message.complete", payload: ["text": "done", "status": "complete"])
        #expect(await eventually { !composer.session.transcript.isRunning })
        await composer.sendNextHeld()
        #expect(composer.heldPrompts.isEmpty)
        #expect(gateway.params("prompt.submit").last == ["session_id": "sid-1", "text": "next"])
    }

    /// Later messages queue behind held ones, and go out one per turn, in order.
    @Test func heldMessagesGoOutOneAtATimeInOrder() async throws {
        let gateway = ScriptedGateway()
        let composer = try await composerMidReply(gateway)
        composer.draft = "second"
        await composer.submit()
        composer.draft = "third"
        await composer.submit()
        #expect(composer.heldPrompts.map(\.text) == ["second", "third"])

        gateway.transport.sendEvent("message.complete", payload: ["text": "done", "status": "complete"])
        #expect(await eventually { !composer.session.transcript.isRunning })
        await composer.sendNextHeld()
        #expect(composer.heldPrompts.map(\.text) == ["third"])
        await composer.sendNextHeld()
        #expect(composer.heldPrompts.map(\.text) == ["third"], "waits for the turn \"second\" starts")
        #expect(gateway.params("prompt.submit").map { $0["text"] } == ["long task", "second"])
    }

    @Test func cancelPutsTheMessageBackIntoAnEmptyComposerOnly() async throws {
        let gateway = ScriptedGateway()
        let composer = try await composerMidReply(gateway)
        composer.draft = "maybe not"
        await composer.submit()
        let held = try #require(composer.heldPrompts.first)

        composer.draft = "something else"
        #expect(!composer.cancelHeld(held.id))
        #expect(composer.heldPrompts.map(\.id) == [held.id])
        #expect(composer.draft == "something else")

        composer.draft = "  "
        #expect(composer.cancelHeld(held.id))
        #expect(composer.heldPrompts.isEmpty)
        #expect(composer.draft == "maybe not")
        #expect(gateway.params("prompt.submit").count == 1)
    }

    @Test func steerHandsAHeldMessageToTheRunningTurn() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.steer") { params in .result(["status": "queued", "text": params["text"] ?? ""]) }
        let composer = try await composerMidReply(gateway)
        composer.draft = "use the staging db"
        await composer.submit()
        #expect(composer.canSteerHeld)

        await composer.steerHeld(try #require(composer.heldPrompts.first).id)
        #expect(composer.heldPrompts.isEmpty)
        #expect(gateway.params("session.steer") == [["session_id": "sid-1", "text": "use the staging db"]])
        #expect(composer.session.transcript.items.last?.isSteer == true)
        #expect(gateway.params("prompt.submit").count == 1)
    }

    @Test func aMessageSentToAnIdleChatGoesStraightOut() async throws {
        let gateway = ScriptedGateway()
        let composer = try await openComposer(gateway)
        composer.draft = "hello"
        await composer.submit()
        #expect(composer.heldPrompts.isEmpty)
        #expect(gateway.params("prompt.submit").map { $0["text"] } == ["hello"])
    }
}
