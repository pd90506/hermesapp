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
    private var lastSearch: SessionWire.SearchSnapshot?
    private var lastCron: SessionWire.CronSnapshot?
    private var lastSubagents: SessionWire.SubagentsSnapshot?
    private var lastUsage: SessionWire.UsageSnapshot?
    /// The chat the connection shows, as the bridge last followed it: a change the
    /// bridge didn't make itself (a slash command's client action, a reconnect) is
    /// adopted, while `closeChat` (which leaves the connection's chat alone) is not.
    private var followed: ChatSession?
    /// The `setDraft` whose slash update is still waited for.
    private var draftRequest = 0
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
        observeSearch()
        observeCron()
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
        case "searchSessions":
            // The profile's chats whose messages, title or id match; the results follow
            // as the `search` snapshot. An empty query clears them.
            await connection.searchSessions(try string(params, "query"))
        case "openSession":
            let id = try string(params, "id")
            // A row of the list, or one the search made from its hit (`result(id:)`),
            // which opens the same way.
            guard let entry = connection.history.first(where: { $0.id == id })
                ?? connection.search.result(id: id)?.entry else {
                throw BridgeError("no session \(id) in the list")
            }
            show(try await connection.open(entry))
        case "openBotChat":
            show(try await connection.openBotChat(profile: try string(params, "profile")))
        case "newChat":
            show(try await connection.newSideChat(profile: try string(params, "profile")))
        case "send":
            guard let chat, let composer else { throw BridgeError("no open chat") }
            let text = params["text"]?.stringValue ?? composer.draft
            composer.draft = text
            if SlashCommand.isCommand(text) {
                // A slash command, as the Mac's submit(): the composer runs it, its
                // client actions included (`/new`, `/model`, …). What it left in the
                // draft (a prefill, a refused command) comes back in the `composer`
                // snapshot.
                _ = await composer.submitSlash()
            } else if composer.attachments.isEmpty && composer.files.isEmpty {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError("missing text") }
                try await chat.send(text)
            } else {
                // With cards, the composer sends them with the text (and puts them back if
                // the send fails, its error in the `composer` snapshot).
                await composer.submit()
            }
        case "interrupt":
            guard let chat else { throw BridgeError("no open chat") }
            try await chat.interrupt()
        case "closeChat":
            show(nil)
        // The composer's draft, kept in step with the app's text field so the slash
        // list follows it (`updateSlashSuggestions`, with Desktop's 60 ms debounce
        // before a lookup the gateway must answer).
        case "setDraft":
            let composer = try requireComposer()
            composer.draft = try string(params, "text")
            let request = draftRequest + 1
            draftRequest = request
            if composer.slashUpdateNeedsRequest {
                try? await Task.sleep(for: .milliseconds(60))
                guard request == draftRequest else { return .null }
            }
            await composer.updateSlashSuggestions()
        // A key the slash list takes (arrows, Tab, Return, Esc). The result is whether
        // the list used it; false leaves it to the text field.
        case "slashKey":
            let composer = try requireComposer()
            let key: SlashListKey
            switch try string(params, "key") {
            case "up": key = .up
            case "down": key = .down
            case "tab": key = .tab
            case "accept": key = .accept
            case "escape": key = .escape
            case let other: throw BridgeError("unknown slash key \(other)")
            }
            return .bool(composer.handleSlashKey(key))
        case "acceptSlashRow":
            try requireComposer().acceptSlashRow(id: try string(params, "id"))
        case "dismissSlashSuggestions":
            try requireComposer().dismissSlashSuggestions()
        // `/model` asked for the picker: the app opens its own and clears the request.
        case "setModelPickerRequested":
            try requireComposer().isModelPickerRequested = params["shown"]?.boolValue ?? false
        // The chat's blocking requests: approval buttons, a clarify's answers, a
        // sudo/secret value, as the Mac's `RequestCardView` answers them.
        case "answerApproval":
            let chat = try requireChat()
            let request = try request(params, in: chat)
            guard case .approval = request.kind else { throw BridgeError("request \(request.id) is not an approval") }
            guard let choice = ApprovalChoice(rawValue: try string(params, "choice")) else {
                throw BridgeError("unknown choice")
            }
            try await chat.answer(request, approval: choice, all: params["all"]?.boolValue ?? false)
        case "answerClarify":
            let chat = try requireChat()
            let request = try request(params, in: chat)
            guard case .clarify = request.kind else { throw BridgeError("request \(request.id) is not a clarify") }
            if let given = params["selections"]?.objectValue {
                // The app stages its own form (`ClarifyForm`); the answers go out together,
                // one `{qid: {choices, other}}` per question answered.
                var selections: [String: ClarifySelection] = [:]
                for (qid, value) in given {
                    selections[qid] = ClarifySelection(
                        choices: value["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                        other: value["other"]?.stringValue ?? "")
                }
                try await chat.answer(request, selections: selections)
            } else {
                // No selections: skip every question.
                try await chat.answer(request, clarify: nil)
            }
        case "answerValue":
            let chat = try requireChat()
            let request = try request(params, in: chat)
            try await chat.answer(request, value: params["value"]?.stringValue ?? "")
        // The chat's subagents (the pill above the composer): reconcile with the
        // gateway's roster, steer one, stop one.
        case "refreshSubagents":
            try await requireChat().refreshSubagents()
        case "steerSubagent":
            let chat = try requireChat()
            _ = try await chat.steerSubagent(try string(params, "id"), text: try string(params, "text"))
        case "stopSubagent":
            let chat = try requireChat()
            _ = try await chat.stopSubagent(try string(params, "id"))
        // The context gauge's numbers, read again as the Mac reads them (on showing
        // the chat, after a turn, after a compression).
        case "refreshUsage":
            try await requireChat().refreshUsage()
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
        case "renameSession":
            // As the Mac's Rename…: a row not open here is opened first (`session.title`
            // needs a live session), and the user sees the chat they renamed.
            let entry = try listed(params)
            let title = try string(params, "title")
            do {
                try await connection.rename(entry, to: title)
            } catch SessionActionError.notOpen {
                show(try await connection.open(entry))
                try await connection.rename(entry, to: title)
            }
        case "forkSession":
            show(try await connection.fork(try listed(params)))
        case "archiveSession":
            let entry = try listed(params)
            try await connection.archive(entry)
            return try unpin(entry)
        case "deleteSession":
            let entry = try listed(params)
            if let chat, chat.storedSessionID == entry.summary.id, chat.profile == entry.profile { show(nil) }
            try await connection.delete(entry)
            return try unpin(entry)
        case "avatar":
            // A profile's avatar image, for the rail: result `{"data": base64}`, or null.
            let data = connection.avatars[try string(params, "profile")]
            return .object(["data": data.map { .string($0.base64EncodedString()) } ?? .null])
        case "setAvatar":
            guard let data = Data(base64Encoded: try string(params, "data")) else { throw BridgeError("data is not base64") }
            try await connection.setAvatar(data, for: try string(params, "profile"))
        case "removeAvatar":
            try await connection.removeAvatar(for: try string(params, "profile"))
        case "imageData":
            // A sent image's bytes, for its thumbnail in the transcript (the Mac's
            // `GatewayConnection.imageData`).
            let data = try await connection.imageData(path: try string(params, "path"),
                                                      profile: params["profile"]?.stringValue)
            return .object(["data": .string(data.base64EncodedString())])
        // The list profile's cron jobs (the sidebar's Cron tab). The jobs and runs
        // follow as the `cron` snapshot; actions answer when they are done.
        case "refreshCronJobs":
            await connection.refreshCronJobs()
        case "refreshCronRuns":
            await connection.refreshCronRuns(try cronJob(params))
        case "loadCronDeliveryTargets":
            await connection.loadCronDeliveryTargets()
        case "loadCronBlueprints":
            await connection.loadCronBlueprints()
        case "pauseCronJob":
            try await connection.pauseCronJob(try cronJob(params))
        case "resumeCronJob":
            try await connection.resumeCronJob(try cronJob(params))
        case "setCronDelivery":
            // The targets the app toggled, as a comma list (`CronJob.deliver(toggling:on:)`).
            try await connection.setCronDelivery(try cronJob(params), to: try string(params, "deliver"))
        case "triggerCronJob":
            try await connection.triggerCronJob(try cronJob(params))
        case "deleteCronJob":
            try await connection.deleteCronJob(try cronJob(params))
        case "openCronRun":
            // A run with a session opens it as a chat of the profile, as the Mac's run
            // row does (`CronRun.historyEntry`).
            let id = try string(params, "id")
            guard let profile = connection.cron.profile,
                  let run = connection.cron.runs.values.flatMap({ $0 }).first(where: { $0.id == id }),
                  !run.isOutputDocument else {
                throw BridgeError("no run \(id)")
            }
            show(try await connection.open(run.historyEntry(profile: profile)))
        // The models a job can pin, the editor's model picker (the composer's catalog
        // shape, without the current choice).
        case "cronModelCatalog":
            let catalog = try await connection.cronModelCatalog()
            return .object(["providers": .array(catalog.providers.map { provider in
                .object(["slug": .string(provider.slug), "name": .string(provider.name),
                         "models": .array(provider.models.map { .string($0) })])
            })])
        case "createCronJob":
            _ = try await connection.createCronJob(try cronDraft(params["draft"] ?? .object([:])))
        case "saveCronJob":
            try await connection.saveCronJob(try cronJob(params), try cronDraft(params["draft"] ?? .object([:])))
        case "instantiateCronBlueprint":
            // A blueprint's blanks filled in, which creates its job.
            let key = try string(params, "key")
            guard let blueprint = connection.cron.blueprints.first(where: { $0.key == key }) else {
                throw BridgeError("no blueprint \(key)")
            }
            let values = params["values"]?.objectValue?.mapValues { $0.stringValue ?? "" } ?? [:]
            _ = try await connection.createCronJob(from: blueprint, values: values)
        default:
            throw BridgeError("unknown method \(method)")
        }
        return .null
    }

    /// The listed session `params["id"]` names.
    private func listed(_ params: JSONValue) throws -> HistoryEntry {
        let id = try string(params, "id")
        guard let entry = connection.history.first(where: { $0.id == id }) else {
            throw BridgeError("no session \(id) in the list")
        }
        return entry
    }

    /// An archived or deleted session leaves the pins, as on the Mac: result
    /// `{"pins": ...}`, for the app to save.
    private func unpin(_ entry: HistoryEntry) throws -> JSONValue {
        pins.setPinned(false, entry, on: pinServer)
        emitConnection()
        return .object(["pins": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(pins))])
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

    private func requireChat() throws -> ChatSession {
        guard let chat else { throw BridgeError("no open chat") }
        return chat
    }

    /// The open chat's request `params["id"]` names, one of `transcript.pendingRequests`.
    private func request(_ params: JSONValue, in chat: ChatSession) throws -> ServerRequest {
        let id = try string(params, "id")
        guard let request = chat.transcript.pendingRequests.first(where: { $0.id == id }) else {
            throw BridgeError("no request \(id) in the chat")
        }
        return request
    }

    /// The listed cron job `params["id"]` names.
    private func cronJob(_ params: JSONValue) throws -> CronJob {
        let id = try string(params, "id")
        guard let job = connection.cron.jobs.first(where: { $0.id == id }) else {
            throw BridgeError("no cron job \(id)")
        }
        return job
    }

    /// The editor's job draft as `createCronJob` and `saveCronJob` take it: what the
    /// app's dialog holds. Absent keys keep what the job already has (a new job, its
    /// defaults); `provider`/`model` together pin a model, `null` for either unpins it.
    private func cronDraft(_ value: JSONValue, editing job: CronJob? = nil) throws -> CronJobDraft {
        var draft = job.map(CronJobDraft.init) ?? CronJobDraft()
        draft.name = value["name"]?.stringValue ?? draft.name
        draft.prompt = value["prompt"]?.stringValue ?? draft.prompt
        if let schedule = value["schedule"] {
            draft.schedule = CronSchedule(
                frequency: schedule["frequency"]?.stringValue.flatMap(CronSchedule.Frequency.init(rawValue:))
                    ?? draft.schedule.frequency,
                hour: schedule["hour"]?.intValue ?? draft.schedule.hour,
                minute: schedule["minute"]?.intValue ?? draft.schedule.minute,
                weekday: schedule["weekday"]?.intValue ?? draft.schedule.weekday,
                dayOfMonth: schedule["dayOfMonth"]?.intValue ?? draft.schedule.dayOfMonth,
                custom: schedule["custom"]?.stringValue ?? draft.schedule.custom)
        }
        draft.deliver = value["deliver"]?.stringValue ?? draft.deliver
        if let provider = value["provider"]?.stringValue, let model = value["model"]?.stringValue {
            draft.model = ModelChoice(provider: provider, model: model)
        } else if value["provider"] == .null || value["model"] == .null {
            draft.model = nil
        }
        return draft
    }

    // MARK: - Snapshots

    private func show(_ chat: ChatSession?) {
        // The same chat again: nothing to reset. (A reopen of the open chat used to
        // make a fresh composer, losing its draft and cards.)
        if chat === self.chat { return }
        self.chat = chat
        // What the connection shows, so a change the bridge didn't make itself is
        // adopted, while `closeChat` (which leaves the connection's chat alone) is not.
        followed = chat ?? connection.activeSession
        composer = chat.map { ChatComposer(session: $0) }
        generation += 1
        lastChat = nil
        lastComposer = nil
        lastSubagents = nil
        lastUsage = nil
        observeConnection(generation)
        if chat != nil {
            observeChat(generation)
            observeComposer(generation)
            observeSubagents(generation)
            observeUsage(generation)
        }
        // The model and effort pickers' choices and the slash catalog, as the Mac's
        // composer loads them on open (a slow catalog must not hold up the pickers).
        if let composer { Task { await composer.loadCommandsAndOptions() } }
    }

    private func observeConnection(_ generation: Int) {
        guard generation == self.generation else { return }
        let snapshot = withObservationTracking {
            // `activeSession` is read so its changes re-run this: a chat the connection
            // shows on its own (a slash command's client action, a reconnect's resume)
            // is adopted below.
            _ = connection.activeSession
            return ConnectionSnapshot(connection, pins: pins, server: pinServer)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeConnection(generation) }
        }
        if connection.activeSession !== followed {
            // The SwiftUI apps follow the connection's own shown session; so does the
            // bridge. `show` restarts every observer at a new generation.
            show(connection.activeSession)
            return
        }
        if snapshot != lastConnection {
            lastConnection = snapshot
            emit(BridgeEvent.connection(snapshot).json())
        }
    }

    /// The session list's search, re-sent whenever it changes. Connection-level, so it
    /// survives every `show`.
    private func observeSearch() {
        let snapshot = withObservationTracking {
            SessionWire.SearchSnapshot(connection)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSearch() }
        }
        if snapshot != lastSearch {
            lastSearch = snapshot
            emit(BridgeEvent.search(snapshot).json())
        }
    }

    /// The list profile's cron jobs, likewise connection-level.
    private func observeCron() {
        let snapshot = withObservationTracking {
            SessionWire.CronSnapshot(connection)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCron() }
        }
        if snapshot != lastCron {
            lastCron = snapshot
            emit(BridgeEvent.cron(snapshot).json())
        }
    }

    /// The open chat's running subagents, as the pill above the composer shows them.
    /// Separate from the chat snapshot: a subagent event changes nothing else, and the
    /// chat's own snapshot is a large JSON to re-send.
    private func observeSubagents(_ generation: Int) {
        guard generation == self.generation, let chat else { return }
        let snapshot = withObservationTracking {
            SessionWire.SubagentsSnapshot(chat)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSubagents(generation) }
        }
        if snapshot != lastSubagents {
            lastSubagents = snapshot
            emit(BridgeEvent.subagents(snapshot).json())
        }
    }

    /// The open chat's context gauge and session counters, for the composer's ring.
    private func observeUsage(_ generation: Int) {
        guard generation == self.generation, let chat else { return }
        let snapshot = withObservationTracking {
            SessionWire.UsageSnapshot(chat)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeUsage(generation) }
        }
        if snapshot != lastUsage {
            lastUsage = snapshot
            emit(BridgeEvent.usage(snapshot).json())
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
