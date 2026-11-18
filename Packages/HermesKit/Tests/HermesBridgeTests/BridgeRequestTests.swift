import Foundation
import HermesKit
import HermesProtocol
import Testing

@testable import HermesBridge

/// The chat's blocking requests, as the transcript's cards: the `chat` snapshot carries
/// them (`pendingRequests`), and the `answer*` commands reply on the wire.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BridgeRequestTests {
    private func openedBridge(outbox: Outbox, server: BridgeServer) async throws -> Bridge {
        let bridge = try await Bridge.connected(server, outbox: outbox)
        try await Bridge.openedChat(bridge, outbox: outbox, server: server)
        return bridge
    }

    @Test func anApprovalArrivesAsACardAndIsAnswered() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server)
        server.transport.sendRequest("approval", id: "srq-1", params: [
            "session_id": "rt-1", "request_id": "req-1", "command": "rm -rf /tmp/x", "description": "Removes files",
            "allow_session": true, "allow_permanent": false, "tool_name": "bash",
        ])
        #expect(await eventually {
            let card = (outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first
            return card?["kind"] as? String == "approval"
        })
        let card = try #require((outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first)
        #expect(card["id"] as? String == "srq-1")
        #expect(card["headline"] as? String == "Approval needed")
        #expect(card["command"] as? String == "rm -rf /tmp/x")
        // allow_permanent false: no Always Allow button.
        let choices = try #require(card["choices"] as? [[String: Any]])
        #expect(choices.map { $0["value"] as? String } == ["once", "session", "deny"])
        #expect(choices.last?["label"] as? String == "Deny")

        try await bridge.receive(#"{"id":"a1","method":"answerApproval","params":{"id":"srq-1","choice":"session"}}"#)
        // The answer is a JSON-RPC response to the request's id, with the choice.
        let frame = try #require(server.log.all.first { $0["id"]?.stringValue == "srq-1" })
        #expect(frame["result"]?["choice"]?.stringValue == "session")
        // The card leaves the snapshot once answered.
        #expect(await eventually {
            (outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.isEmpty ?? false
        })
    }

    @Test func anApprovalTheChatDoesNotHoldIsRefused() async throws {
        let outbox = Outbox()
        let bridge = try await openedBridge(outbox: outbox, server: BridgeServer())
        try await bridge.receive(#"{"id":"a1","method":"answerApproval","params":{"id":"srq-9","choice":"once"}}"#)
        #expect(outbox.last["error"] as? String == "no request srq-9 in the chat")
    }

    @Test func clarifyAnswersGoOutTogetherAndCanBeSkipped() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server)
        server.transport.sendRequest("clarify", id: "srq-2", params: [
            "session_id": "rt-1",
            "questions": [
                ["qid": "q1", "question": "Which?", "choices": ["Red", "Blue"]],
                ["qid": "q2", "question": "Tags?", "choices": ["a", "b"], "multi_select": true],
            ],
        ])
        #expect(await eventually {
            let card = (outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first
            return card?["kind"] as? String == "clarify"
        })
        let card = try #require((outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first)
        #expect(card["headline"] as? String == "Hermes has 2 questions")
        let questions = try #require(card["questions"] as? [[String: Any]])
        #expect(questions.map { $0["qid"] as? String } == ["q1", "q2"])
        #expect(questions[1]["multiSelect"] as? Bool == true)
        #expect((questions[1]["choices"] as? [Any])?.count == 2)

        // The app's form, sent as one answer: a single choice, a multi-select with its
        // typed extra.
        try await bridge.receive(#"""
            {"id":"a1","method":"answerClarify","params":{"id":"srq-2","selections":{
              "q1":{"choices":["Red"]},"q2":{"choices":["a"],"other":"tagged"}}}}
            """#)
        let frame = try #require(server.log.all.first { $0["id"]?.stringValue == "srq-2" })
        let answers = try #require(frame["result"]?["answers"]?.objectValue)
        #expect(answers["q1"]?.stringValue == "Red")
        // A multi-select answers as a JSON array string: the bare choices, then the text.
        let raw = try #require(answers["q2"]?.stringValue)
        let listed = try #require(raw.data(using: .utf8))
        #expect(try JSONDecoder().decode([String].self, from: listed) == ["a", "tagged"])

        // No selections: every question is skipped (a cancel).
        server.transport.sendRequest("clarify", id: "srq-3", params: [
            "session_id": "rt-1", "questions": [["qid": "q1", "question": "Again?"]],
        ])
        #expect(await eventually {
            (outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.contains { $0["id"] as? String == "srq-3" }
                ?? false
        })
        try await bridge.receive(#"{"id":"a2","method":"answerClarify","params":{"id":"srq-3"}}"#)
        let skipped = try #require(server.log.all.first { $0["id"]?.stringValue == "srq-3" })
        // No selections is a cancel: the answers key is absent altogether.
        #expect(skipped["result"]?["answers"] == nil)
    }

    @Test func sudoAndSecretTakeAValue() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server)
        server.transport.sendRequest("sudo", id: "srq-4", params: [
            "session_id": "rt-1", "command": "apt-get install x",
        ])
        #expect(await eventually {
            let card = (outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first
            return card?["kind"] as? String == "sudo"
        })
        let card = try #require((outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first)
        #expect(card["headline"] as? String == "Sudo password requested")
        #expect(card["command"] as? String == "apt-get install x")

        try await bridge.receive(#"{"id":"v1","method":"answerValue","params":{"id":"srq-4","value":"hunter2"}}"#)
        let frame = try #require(server.log.all.first { $0["id"]?.stringValue == "srq-4" })
        #expect(frame["result"]?["value"]?.stringValue == "hunter2")

        // A secret names its variable and shows its own prompt as the headline.
        server.transport.sendRequest("secret", id: "srq-5", params: [
            "session_id": "rt-1", "env_var": "OPENCODE_GO_API_KEY", "prompt": "Sign in to the provider",
        ])
        #expect(await eventually {
            let card = (outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first
            return card?["kind"] as? String == "secret"
        })
        let secret = try #require((outbox.last("chat")?["pendingRequests"] as? [[String: Any]])?.first)
        #expect(secret["headline"] as? String == "Sign in to the provider")
        #expect(secret["envVar"] as? String == "OPENCODE_GO_API_KEY")
        // An empty value means "skip".
        try await bridge.receive(#"{"id":"v2","method":"answerValue","params":{"id":"srq-5","value":""}}"#)
        let skipped = try #require(server.log.all.first { $0["id"]?.stringValue == "srq-5" })
        #expect(skipped["result"]?["value"]?.stringValue == "")
    }
}
