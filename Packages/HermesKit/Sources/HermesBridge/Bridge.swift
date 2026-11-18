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
    /// The open chat's composer: its pickers and attachment cards.
    private(set) var composer: ChatComposer?
    /// Bumped whenever the observed objects change, so stale observers stop.
    private var generation = 0
    private var lastConnection: ConnectionSnapshot?
    private var lastChat: ChatSnapshot?
    private var lastComposer: ComposerSnapshot?
    /// The sessions pinned to the top of the list (`SessionPins`), kept by the app
    /// (`setPins`), and the server they belong to.
    private var pins = SessionPins()
    private var pinServer = UUID()
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
            guard let chat, let composer else { throw BridgeError("no open chat") }
            let text = params["text"]?.stringValue ?? ""
            if composer.attachments.isEmpty && composer.files.isEmpty {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError("missing text") }
                try await chat.send(text)
            } else {
                // With cards, the composer sends them with the text (and puts them back if
                // the send fails, its error in the `composer` snapshot).
                composer.draft = text
                await composer.submit()
            }
        case "interrupt":
            guard let chat else { throw BridgeError("no open chat") }
            try await chat.interrupt()
        case "closeChat":
            show(nil)
        case "deleteChat":
            guard let chat else { throw BridgeError("no open chat") }
            show(nil)
            try await connection.delete(chat)
        case "branch":
            // Branch in New Chat from a message (the Mac's action bar), which then opens.
            guard let chat else { throw BridgeError("no open chat") }
            let item = try transcriptItem(params, in: chat)
            show(try await connection.branch(chat, at: item))
        case "messageSource":
            // What Copy Message copies (`ConversationMarkdown.messageSource`).
            guard let chat else { throw BridgeError("no open chat") }
            return .object(["text": .string(ConversationMarkdown.messageSource(for: try transcriptItem(params, in: chat)))])
        case "conversationSource":
            // What Copy Conversation copies: the chat as Markdown.
            guard let chat else { throw BridgeError("no open chat") }
            return .object(["text": .string(ConversationMarkdown.export(chat.transcript.items))])
        case "reloadModels":
            try await requireComposer().loadOptions()
        case "selectModel":
            let composer = try requireComposer()
            await composer.selectModel(ModelChoice(provider: try string(params, "provider"), model: try string(params, "model")))
        case "confirmModelSwitch":
            try await requireComposer().confirmPendingModelSwitch()
        case "cancelModelSwitch":
            try requireComposer().cancelPendingModelSwitch()
        case "selectEffort":
            let composer = try requireComposer()
            await composer.selectEffort(try string(params, "effort"))
        case "attachFile":
            let composer = try requireComposer()
            let file = try AttachmentFile.load(path: try string(params, "path"))
            return try await attach(file.data, filename: file.filename, to: composer)
        case "attachData":
            let composer = try requireComposer()
            guard let data = Data(base64Encoded: try string(params, "data")) else { throw BridgeError("data is not base64") }
            return try await attach(data, filename: try string(params, "filename"), to: composer)
        case "removeAttachment":
            let id = try string(params, "id")
            guard let uuid = UUID(uuidString: id) else { throw BridgeError("no attachment \(id)") }
            try requireComposer().removeAttachment(id: uuid)
        case "dismissComposerError":
            try requireComposer().error = nil
        case "decidePaste":
            return decidePaste(params)
        case "setPins":
            guard let server = UUID(uuidString: try string(params, "server")) else { throw BridgeError("server is not a UUID") }
            pinServer = server
            // None saved yet (absent or null): no pins.
            if let saved = params["pins"], saved != .null {
                pins = try saved.decode(SessionPins.self)
            } else {
                pins = SessionPins()
            }
            emitConnection()
        case "pinSession":
            let id = try string(params, "id")
            guard let entry = connection.history.first(where: { $0.id == id }) else {
                throw BridgeError("no session \(id) in the list")
            }
            pins.setPinned(params["pinned"].flatMap { if case .bool(let value) = $0 { value } else { nil } } ?? true,
                           entry, on: pinServer)
            emitConnection()
            return .object(["pins": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(pins))])
        case "imageData":
            // A sent image's bytes, for its thumbnail in the transcript (the Mac's
            // `GatewayConnection.imageData`).
            let data = try await connection.imageData(path: try string(params, "path"),
                                                      profile: params["profile"]?.stringValue)
            return .object(["data": .string(data.base64EncodedString())])
        default:
            throw BridgeError("unknown method \(method)")
        }
        return .null
    }

    private func transcriptItem(_ params: JSONValue, in chat: ChatSession) throws -> TranscriptItem {
        let id = try string(params, "item")
        guard let item = chat.transcript.items.first(where: { $0.id == id }) else {
            throw BridgeError("no item \(id) in the chat")
        }
        return item
    }

    private func requireComposer() throws -> ChatComposer {
        guard let composer else { throw BridgeError("no open chat") }
        return composer
    }

    /// Attaches a file's contents (`ChatComposer.attachFile`: an image Hermes takes as it
    /// is becomes an image card, anything else is staged with `file.attach`) and answers
    /// `{"id": card id}`, so the app can match a thumbnail to the card.
    private func attach(_ data: Data, filename: String, to composer: ChatComposer) async throws -> JSONValue {
        let before = Set(composer.attachments.map(\.id) + composer.files.map(\.id))
        guard await composer.attachFile(data, filename: filename) else {
            throw BridgeError(composer.error ?? "Couldn't attach \(filename)")
        }
        let added = (composer.attachments.map(\.id) + composer.files.map(\.id)).first { !before.contains($0) }
        return .object(["id": added.map { .string($0.uuidString) } ?? .null])
    }

    /// What a paste into the composer does (`ClipboardPolicy`), from what the app read off
    /// the clipboard: `types` (uniform type identifiers), `string`, `files` (paths).
    private func decidePaste(_ params: JSONValue) -> JSONValue {
        func strings(_ key: String) -> [String] {
            guard case .array(let values)? = params[key] else { return [] }
            return values.compactMap(\.stringValue)
        }
        let files = strings("files")
        let contents = ClipboardPolicy.Contents(types: strings("types"), string: params["string"]?.stringValue,
                                                fileURLs: files.map { URL(fileURLWithPath: $0) })
        let decision = ClipboardPolicy.decide(contents)
        if case .files = decision {
            // The paths as the app gave them: a URL's own spelling of a Windows path differs.
            return .object(["decision": .string("files"), "files": .array(files.map(JSONValue.string))])
        }
        return decision.json
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
        composer = chat.map { ChatComposer(session: $0) }
        generation += 1
        lastChat = nil
        lastComposer = nil
        observeConnection(generation)
        if chat != nil {
            observeChat(generation)
            observeComposer(generation)
        }
        // The model and effort pickers' choices, as the Mac's composer loads them on open.
        if let composer { Task { await composer.loadOptions() } }
    }

    private func observeConnection(_ generation: Int) {
        guard generation == self.generation else { return }
        let snapshot = withObservationTracking {
            ConnectionSnapshot(connection, pins: pins, server: pinServer)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeConnection(generation) }
        }
        if snapshot != lastConnection {
            lastConnection = snapshot
            emit(BridgeEvent.connection(snapshot).json())
        }
    }

    /// Sends the connection snapshot again after a change the observation doesn't see
    /// (the pins, which the bridge keeps).
    private func emitConnection() {
        let snapshot = ConnectionSnapshot(connection, pins: pins, server: pinServer)
        if snapshot != lastConnection {
            lastConnection = snapshot
            emit(BridgeEvent.connection(snapshot).json())
        }
    }

    private func observeComposer(_ generation: Int) {
        guard generation == self.generation, let composer else { return }
        let snapshot = withObservationTracking {
            ComposerSnapshot(composer)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeComposer(generation) }
        }
        if snapshot != lastComposer {
            lastComposer = snapshot
            emit(BridgeEvent.composer(snapshot).json())
        }
    }

    private func observeChat(_ generation: Int) {
        guard generation == self.generation, let chat else { return }
        let snapshot = withObservationTracking {
            ChatSnapshot(chat, markdown: markdown, canBranch: !connection.isProtected(chat))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeChat(generation) }
        }
        if snapshot != lastChat {
            lastChat = snapshot
            emit(BridgeEvent.chat(snapshot).json())
        }
    }
}
