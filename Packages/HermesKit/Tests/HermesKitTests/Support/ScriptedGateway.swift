import Foundation
import HermesProtocol
import Synchronization

@testable import HermesKit

/// How the scripted gateway answers one request.
enum Reply: Sendable {
    case result(JSONValue)
    case error(code: Int, message: String)
}

/// A scripted gateway whose answers the test can change while it runs.
/// Methods without a reply are left unanswered.
final class ScriptedGateway: Sendable {
    let log = FrameLog()
    let transport = FakeTransport()
    private let replies: Mutex<[String: @Sendable (JSONValue) -> Reply?]>

    init(_ replies: [String: @Sendable (JSONValue) -> Reply?] = [:]) {
        self.replies = Mutex(replies)
    }

    func on(_ method: String, _ reply: @escaping @Sendable (JSONValue) -> Reply?) {
        replies.withLock { $0[method] = reply }
    }

    func on(_ method: String, result: JSONValue) {
        on(method) { _ in .result(result) }
    }

    func start(epoch: String = "epoch-1") {
        transport.sendReady(epoch: epoch)
        Task {
            while !self.transport.isClosed {
                guard let frame = await self.transport.readSent() else { break }
                self.log.append(frame)
                guard let method = frame["method"]?.stringValue, frame["id"] != nil else { continue }
                if method == "client.capabilities" {
                    self.transport.respond(to: frame, result: ["server_requests": ["approval", "clarify", "sudo", "secret"]])
                    continue
                }
                let handler = self.replies.withLock { $0[method] }
                switch handler?(frame["params"] ?? .null) {
                case .result(let value)?: self.transport.respond(to: frame, result: value)
                case .error(let code, let message)?: self.transport.respondError(to: frame, code: code, message: message)
                case nil: break
                }
            }
        }
    }

    func params(_ method: String) -> [JSONValue] { log.requests(method).map { $0["params"] ?? .null } }
}

// MARK: Hermes-shaped payloads

/// `session.create` result (`contracts/sessions.py:142-147`).
func createdPayload(sid: String, key: String) -> JSONValue {
    ["session_id": .string(sid), "stored_session_id": .string(key), "message_count": 0, "messages": [],
     "info": ["model": "test-model"]]
}

/// Resume payload as Hermes sends it: `session_key`, no `stored_session_id`
/// (`methods_session.py:908-911`).
func resumedPayload(sid: String, key: String, messages: JSONValue = [], running: Bool = false) -> JSONValue {
    ["session_id": .string(sid), "resumed": .string(key), "session_key": .string(key),
     "message_count": .number(Double(messages.arrayValue?.count ?? 0)), "messages": messages,
     "info": ["model": "test-model"], "running": .bool(running), "status": "idle", "inflight": nil]
}

/// A plain `session.list` row (`methods_session.py:118-126,575`).
func sessionRow(id: String, title: String = "") -> JSONValue {
    ["id": .string(id), "title": .string(title), "preview": "", "started_at": 1_700_000_000,
     "message_count": 2, "source": "desktop"]
}

@MainActor
func makeTestConnection() -> GatewayConnection {
    var configuration = GatewayClient.Configuration()
    configuration.heartbeatInterval = nil
    return GatewayConnection(configuration: configuration, backoff: { _ in .milliseconds(1) })
}

extension ScriptedGateway {
    /// Default answers for a connect (empty lists and roster) where the test set none.
    func withDefaults() -> ScriptedGateway {
        let defaults: [String: JSONValue] = [
            "session.list": ["sessions": []],
            "profiles.list": ["profiles": [], "bot_mode_protocol": true, "install_id": "test"],
            "prompt.submit": ["status": "streaming"],
            // An empty catalog (`methods_tools.py:503-537`): `runSlash` loads one before gateway commands.
            "commands.catalog": ["pairs": [], "sub": [:], "canon": [:], "commands": [:], "categories": [],
                                 "skills": [:], "skill_count": 0, "warning": ""],
        ]
        replies.withLock { replies in
            for (method, result) in defaults where replies[method] == nil { replies[method] = { _ in .result(result) } }
        }
        return self
    }

    @MainActor
    func connect() async throws -> GatewayConnection {
        start()
        let connection = makeTestConnection()
        try await connection.connect(using: FakeConnector([transport]))
        return connection
    }
}

/// Holds connections for the length of a test (sessions only reference theirs weakly).
@MainActor
final class ConnectionKeeper {
    private var connections: [GatewayConnection] = []

    nonisolated init() {}

    func keep(_ connection: GatewayConnection) { connections.append(connection) }
}
