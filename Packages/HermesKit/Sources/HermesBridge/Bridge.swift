import Foundation
import HermesKit
import HermesProtocol
import Observation

/// A command from the desktop app: `{"id": "...", "method": "...", "params": {...}}`.
struct BridgeCommand: Decodable, Sendable {
    var id: String
    var method: String
    var params: JSONValue?
}

struct BridgeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Drives one `GatewayConnection` for the desktop app.
///
/// Commands run on the main actor, like the SwiftUI apps' calls. State goes out as whole
/// snapshots, re-sent whenever an observed property changes: a `connection` snapshot for
/// the connection, bots and session list, and a `chat` snapshot for the open chat. Only
/// changed snapshots are sent.
@MainActor
final class Bridge {
    private let emit: @Sendable (String) -> Void
    private let makeConnector: (GatewayEndpoint, GatewayCredential) -> any GatewayConnector
    private(set) var connection = GatewayConnection()
    private(set) var chat: ChatSession?
    /// Bumped whenever the observed objects change, so stale observers stop.
    private var generation = 0
    private var lastConnection: ConnectionSnapshot?
    private var lastChat: ChatSnapshot?
    private let markdown = MarkdownCache()

    init(emit: @escaping @Sendable (String) -> Void,
         makeConnector: @escaping (GatewayEndpoint, GatewayCredential) -> any GatewayConnector = {
             DashboardConnector(endpoint: $0, credential: $1)
         }) {
        self.emit = emit
        self.makeConnector = makeConnector
        observeConnection(generation)
    }

    /// Decodes and runs one command, then replies with its id.
    func receive(_ json: String) async {
        guard let command = try? JSONDecoder().decode(BridgeCommand.self, from: Data(json.utf8)) else {
            emit(BridgeEvent.failure(id: "", message: "malformed command").json())
            return
        }
        do {
            let result = try await run(command.method, command.params ?? .object([:]))
            emit(BridgeEvent.reply(id: command.id, result: result).json())
        } catch {
            emit(BridgeEvent.failure(id: command.id, message: String(describing: error)).json())
        }
    }

    // MARK: - Commands

    private func run(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "connect":
            try await connect(params)
        case "disconnect":
            await connection.disconnect()
            show(nil)
        case "refreshBots":
            try await connection.refreshBots()
        case "selectProfile":
            connection.selectListProfile(params["profile"]?.stringValue)
            await connection.refreshSessionList()
        case "refreshSessions":
            await connection.refreshSessionList()
        case "openSession":
            let id = try string(params, "id")
            guard let entry = connection.history.first(where: { $0.id == id }) else {
                throw BridgeError("no session \(id) in the list")
            }
            show(try await connection.open(entry))
        case "openBotChat":
            show(try await connection.openBotChat(profile: try string(params, "profile")))
        case "newChat":
            show(try await connection.newSideChat(profile: try string(params, "profile")))
        case "send":
            guard let chat else { throw BridgeError("no open chat") }
            try await chat.send(try string(params, "text"))
        case "interrupt":
            guard let chat else { throw BridgeError("no open chat") }
            try await chat.interrupt()
        case "closeChat":
            show(nil)
        case "deleteChat":
            guard let chat else { throw BridgeError("no open chat") }
            show(nil)
            try await connection.delete(chat)
        default:
            throw BridgeError("unknown method \(method)")
        }
        return .null
    }

    /// `{url, token}` for a token (un-gated loopback dashboard), `{url, accessToken}` for a
    /// bearer token, or `{url, username, password, provider?}` for a password login.
    private func connect(_ params: JSONValue) async throws {
        let endpoint = try GatewayEndpoint(try string(params, "url"))
        let credential: GatewayCredential
        if let token = params["token"]?.stringValue {
            credential = .sessionToken(token)
        } else if let token = params["accessToken"]?.stringValue {
            credential = .bearer(accessToken: token)
        } else {
            credential = .password(provider: params["provider"]?.stringValue ?? "basic",
                                   username: try string(params, "username"),
                                   password: try string(params, "password"))
        }
        if connection.state != .disconnected {
            await connection.disconnect()
            show(nil)
        }
        try await connection.connect(using: makeConnector(endpoint, credential))
        try await connection.refreshBots()
    }

    private func string(_ params: JSONValue, _ key: String) throws -> String {
        guard let value = params[key]?.stringValue else { throw BridgeError("missing \(key)") }
        return value
    }

    // MARK: - Snapshots

    private func show(_ chat: ChatSession?) {
        self.chat = chat
        generation += 1
        lastChat = nil
        observeConnection(generation)
        if chat != nil { observeChat(generation) }
    }

    private func observeConnection(_ generation: Int) {
        guard generation == self.generation else { return }
        let snapshot = withObservationTracking {
            ConnectionSnapshot(connection)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeConnection(generation) }
        }
        if snapshot != lastConnection {
            lastConnection = snapshot
            emit(BridgeEvent.connection(snapshot).json())
        }
    }

    private func observeChat(_ generation: Int) {
        guard generation == self.generation, let chat else { return }
        let snapshot = withObservationTracking {
            ChatSnapshot(chat, markdown: markdown)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeChat(generation) }
        }
        if snapshot != lastChat {
            lastChat = snapshot
            emit(BridgeEvent.chat(snapshot).json())
        }
    }
}
