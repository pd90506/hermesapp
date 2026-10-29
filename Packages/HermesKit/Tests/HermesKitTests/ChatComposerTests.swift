import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

// Fixture shapes, as Hermes sends them:
// - session.create's lazy info has `model` but no `provider` / `reasoning_effort`
//   (`tui_gateway/server.py:2831-2839`).
// - model.options: `{providers, model, provider}` (`hermes_cli/inventory.py:165`), with
//   per-model `{fast, reasoning, ultrafast?, can_disable_reasoning?}` (:344-358).
// - config.get reasoning: `{value, display}` (`tui_gateway/methods_config.py:206-224`).
// - config.set model: `{key, value, warning, confirm_required, confirm_message, scope}`
//   (`methods_config_set.py:161-163`); reasoning: `{key, value}` (:336).
// - image.attach_bytes: `{attached, path, count, remainder, text, bytes, name, width?, height?,
//   token_estimate?}` (`methods_prompt.py:912-914,1222-1226`, `server.py:861-870`).
// - image.detach: `{detached, count}` (`methods_prompt.py:1009-1010`).
// - config.set model during a turn: `{key, value:<model>, warning:"", confirm_required:false,
//   confirm_message:"", scope:"session", deferred:true}` (`methods_config_set.py:62-66,88-91`).
// - prompt.submit on a busy session with images: `{status:"queued"}` (`session_auto_continue.py:448`).
// Errors: 4018 "image too large (<n> bytes; cap is 25 MB)" (`prompt_attachments.py:57-60`); 4090
// "Hermes is at the active session limit (n/m). …" (`methods_prompt.py:720-724`,
// `hermes_cli/active_sessions.py:88-98`).

private let lazyCreate: JSONValue = [
    "session_id": "sid-1", "stored_session_id": "stored-new", "message_count": 0, "messages": [],
    "info": ["cwd": "/home/u", "model": "claude-opus-5-5", "tools": [:], "skills": [:], "lazy": true,
             "profile_name": "coder"],
]

private let modelOptions: JSONValue = [
    "providers": [
        ["slug": "anthropic", "name": "Anthropic", "models": ["claude-opus-5-5", "claude-haiku-4-5-20251001"],
         "total_models": 2, "is_current": true, "authenticated": true,
         "capabilities": ["claude-opus-5-5": ["fast": false, "reasoning": true],
                          "claude-haiku-4-5-20251001": ["fast": false, "reasoning": false]]],
        ["slug": "openrouter", "name": "OpenRouter", "models": ["deepseek/deepseek-v4"], "total_models": 1,
         "is_current": false,
         "capabilities": ["deepseek/deepseek-v4": ["fast": false, "reasoning": true, "can_disable_reasoning": false]]],
        ["slug": "nous", "name": "Nous Portal", "models": [], "total_models": 0],
    ],
    "model": "claude-opus-5-5", "provider": "anthropic",
]

private func attachResult(path: String, bytes: Int) -> JSONValue {
    ["attached": true, "path": .string(path), "count": 1, "remainder": "",
     "text": .string("[User attached image: \((path as NSString).lastPathComponent)]"),
     "bytes": .number(Double(bytes)), "name": .string((path as NSString).lastPathComponent),
     "width": 2, "height": 1, "token_estimate": 85]
}

/// Answers the composer's calls. `confirmModel`: a model switch first answers
/// `confirm_required` until resent with `confirm_expensive_model`. `deferModel`:
/// switches answer as during a running turn.
private func composerServer(confirmModel: Bool, deferModel: Bool = false) -> @Sendable (String, JSONValue) -> JSONValue? {
    let uploads = Mutex(0)
    let submits = Mutex(0)
    return { method, params in
        switch method {
        case "session.list": return ["sessions": []]
        case "profiles.list": return ["profiles": []]
        case "session.create": return lazyCreate
        case "model.options": return modelOptions
        case "config.get": return ["value": "high", "display": "show"]
        case "config.set":
            if params["key"] == "reasoning" { return ["key": "reasoning", "value": params["value"] ?? .null] }
            let value = params["value"]?.stringValue ?? ""
            if confirmModel && params["confirm_expensive_model"] == nil {
                return ["key": "model", "value": .string(value), "warning": "Opus is expensive",
                        "confirm_required": true, "confirm_message": "Opus is expensive", "scope": "session"]
            }
            var answer: [String: JSONValue] = [
                "key": "model", "value": .string(String(value.split(separator: " ").first ?? "")),
                "warning": "", "confirm_required": false, "confirm_message": "", "scope": "session"]
            if deferModel { answer["deferred"] = true }
            return .object(answer)
        case "image.attach_bytes":
            let filename = params["filename"]?.stringValue ?? ""
            let n = uploads.withLock { $0 += 1; return $0 }
            let ext = (filename as NSString).pathExtension
            return attachResult(path: "/home/u/.hermes/images/upload_20261006_120000_\(n).\(ext)", bytes: 4)
        case "image.detach": return ["detached": true, "count": 0]
        case "prompt.submit":
            // The first turn streams; the fake never ends it, so later submits are busy ones.
            let n = submits.withLock { $0 += 1; return $0 }
            return ["status": n == 1 ? "streaming" : "queued"]
        default: return nil
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatComposerTests {
    /// A side chat on profile `coder`. Requests matching `unanswered` are left
    /// for the test to fail with `failNext`.
    /// `reconnectTo`: transports for later connection attempts (after a drop).
    private func makeComposer(log: FrameLog, confirmModel: Bool = false, deferModel: Bool = false,
                              reconnectTo: [FakeTransport] = [], requestTimeout: Duration? = nil,
                              unanswered: @escaping @Sendable (String, JSONValue) -> Bool = { _, _ in false })
        async throws -> (ChatComposer, FakeTransport)
    {
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        if let requestTimeout { configuration.requestTimeout = requestTimeout }
        let connection = GatewayConnection(configuration: configuration, backoff: { _ in .milliseconds(1) })
        let transport = FakeTransport()
        let server = composerServer(confirmModel: confirmModel, deferModel: deferModel)
        transport.serve(log: log) { method, params in
            unanswered(method, params) ? nil : server(method, params)
        }
        try await connection.connect(using: FakeConnector([transport] + reconnectTo))
        let session = try await connection.newSideChat(profile: "coder")
        connections.append(connection)  // a session only holds its connection weakly
        return (ChatComposer(session: session), transport)
    }

    private final class Connections {
        private(set) var all: [GatewayConnection] = []
        func append(_ connection: GatewayConnection) { all.append(connection) }
    }

    private let connections = Connections()

    /// Waits for the first logged request matching `match` and answers it with an RPC error.
    private func failNext(_ method: String, where match: (JSONValue) -> Bool = { _ in true }, in log: FrameLog,
                          on transport: FakeTransport, code: Int, message: String) async throws {
        for _ in 0..<300 {
            if let request = log.requests(method).first(where: match) {
                transport.respondError(to: request, code: code, message: message)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("no \(method) request arrived")
    }

    private func png(_ name: String) -> ComposerAttachment {
        ComposerAttachment(filename: name, data: Data([0x89, 0x50, 0x4E, 0x47]), pixelWidth: 2, pixelHeight: 1)
    }

    /// The UIKit bridge supplies its visible text before invoking this model path.
    /// This tests the submit boundary only; it does not emulate an input method.
    @Test func visiblePinyinDraftSendsOnceAndKeepsTextTypedDuringSubmit() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log, unanswered: { method, _ in
            method == "prompt.submit"
        })
        let visible = "请检查这个问题v"
        composer.draft = visible
        let sending = Task { await composer.submit() }
        try #require(await eventually { !log.requests("prompt.submit").isEmpty })
        #expect(composer.draft.isEmpty)
        let pending = try #require(composer.session.transcript.items.first(where: { $0.role == .user }))
        #expect(pending.text == visible)
        #expect(pending.outgoingStatus == "Sending…")
        #expect(log.requests("prompt.submit").count == 1)
        #expect(log.requests("prompt.submit").first?["params"]?["text"] == .string(visible))
        composer.draft = "下一条消息"
        // A duplicate tap while the first submit is pending cannot submit again.
        await composer.submit()
        #expect(log.requests("prompt.submit").count == 1)
        let request = try #require(log.requests("prompt.submit").first)
        transport.respond(to: request, result: ["status": "streaming"])
        await sending.value
        #expect(composer.draft == "下一条消息")
        #expect(composer.session.transcript.items.filter { $0.role == .user }.count == 1)
        #expect(composer.session.transcript.items.first(where: { $0.id == pending.id })?.outgoingStatus == nil)
    }

    /// An image uploads as soon as it is attached (as in Claude Code), and Send waits
    /// for it: the card shows it uploading meanwhile.
    @Test func anImageUploadsWhenAttachedAndSendWaitsForIt() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log, unanswered: { method, _ in
            method == "image.attach_bytes"
        })
        let image = png("early.png")
        composer.attach(image)
        composer.draft = "caption"
        try #require(await eventually { !log.requests("image.attach_bytes").isEmpty })
        #expect(composer.uploadingImageIDs == [image.id])
        #expect(!composer.canSubmit)
        let request = try #require(log.requests("image.attach_bytes").first)
        transport.respond(to: request, result: attachResult(path: "/home/u/.hermes/images/early.png", bytes: 4))
        #expect(await eventually { composer.canSubmit })
        #expect(composer.uploadingImageIDs.isEmpty && composer.failedImageUploads.isEmpty)
        await composer.submit()
        // Not uploaded again: the send only submits.
        #expect(log.requests("image.attach_bytes").count == 1)
        #expect(log.requests("prompt.submit").map { $0["params"] } == [["session_id": "sid-1", "text": "caption"]])
        let bubble = try #require(composer.session.transcript.items.last)
        #expect(bubble.images.map(\.path) == ["/home/u/.hermes/images/early.png"])
        #expect(bubble.images.first?.localID == image.id)
    }

    /// A card whose early upload failed says so; Send is not held up by it, and the
    /// send uploads it again. A send that fails then puts the message back once.
    @Test func aFailedEarlyUploadIsRetriedBySendingAndAFailureThereKeepsTheMessage() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log, unanswered: { method, _ in
            method == "image.attach_bytes"
        })
        let image = png("pending.png")
        composer.attach(image)
        try await failNext("image.attach_bytes", in: log, on: transport, code: 4018, message: "image too large")
        #expect(await eventually { composer.failedImageUploads[image.id] != nil })
        #expect(composer.failedImageUploads[image.id]?.contains("image too large") == true)
        #expect(composer.canSubmit)
        composer.draft = "caption"
        let sending = Task { await composer.submit() }
        try #require(await eventually { log.requests("image.attach_bytes").count == 2 })
        let pending = try #require(composer.session.transcript.items.first(where: { $0.role == .user }))
        #expect(pending.outgoingStatus == "Sending…")
        #expect(pending.text == "caption" && pending.images.first?.localID == image.id)
        #expect(pending.images.first?.path == nil)
        // The card left the composer with the send.
        #expect(composer.attachments.isEmpty)
        composer.draft = "new text"
        let request = try #require(log.requests("image.attach_bytes").last)
        transport.respondError(to: request, code: 4018, message: "image too large")
        await sending.value
        // Never submitted: the message goes back to the composer, shown once there.
        #expect(composer.session.transcript.items.isEmpty)
        #expect(composer.draft == "caption\nnew text")
        #expect(composer.attachments.map(\.id) == [image.id])
        #expect(composer.error?.contains("image too large") == true)
        #expect(log.requests("prompt.submit").isEmpty)
    }

    /// A submit that went out and failed may have run: the bubble keeps the text and says
    /// so, and nothing is sent again by itself.
    @Test func failedDispatchedSubmitStaysUnconfirmedAndIsNotRetried() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log, unanswered: { method, _ in
            method == "prompt.submit"
        })
        composer.draft = "hello"
        let sending = Task { await composer.submit() }
        let request = try #require(await eventually { !log.requests("prompt.submit").isEmpty } ? log.requests("prompt.submit").first : nil)
        transport.respondError(to: request, code: 5000, message: "agent crashed")
        await sending.value
        let failed = try #require(composer.session.transcript.items.last)
        #expect(failed.text == "hello")
        #expect(failed.outgoingStatus?.hasPrefix("Not confirmed") == true)
        #expect(composer.session.transcript.failedPrompts.map(\.id) == [failed.id])
        #expect(composer.draft.isEmpty)
        #expect(log.requests("prompt.submit").count == 1)
    }

    /// Text-only, offline: the submit never went out, and the bubble says that.
    @Test func undispatchedTextOnlyFailureSaysNotSent() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        try await #require(connections.all.last).disconnect()
        composer.draft = "offline"
        await composer.submit()
        let failed = try #require(composer.session.transcript.items.last)
        #expect(failed.text == "offline")
        #expect(failed.outgoingStatus?.hasPrefix("Not sent") == true)
        #expect(composer.session.transcript.failedPrompts.count == 1)
        #expect(log.requests("prompt.submit").isEmpty)
    }

    @Test func eachImageUploadsThenTheSendSubmitsAndClearsTheCards() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        #expect(composer.attach(png("a.png")))
        #expect(composer.attach(png("b.jpg")))
        composer.draft = "  what is this?  "
        #expect(await eventually { composer.canSubmit })

        await composer.submit()

        let uploads = log.requests("image.attach_bytes").map { $0["params"] }
        #expect(uploads == [
            ["session_id": "sid-1", "profile": "coder", "content_base64": "iVBORw==", "filename": "a.png"],
            ["session_id": "sid-1", "profile": "coder", "content_base64": "iVBORw==", "filename": "b.jpg"],
        ])
        #expect(log.requests("prompt.submit").map { $0["params"] } == [["session_id": "sid-1", "text": "what is this?"]])
        // Uploads strictly precede the submit.
        let methods = log.all.compactMap { $0["method"]?.stringValue }
        #expect(methods.lastIndex(of: "image.attach_bytes")! < methods.firstIndex(of: "prompt.submit")!)
        #expect(log.requests("image.detach").isEmpty)
        #expect(composer.attachments.isEmpty)
        #expect(composer.draft.isEmpty)
        #expect(composer.error == nil)
        // The bubble: the caption, and the images with their local ids and gateway paths.
        let bubble = try #require(composer.session.transcript.items.last)
        #expect(bubble.text == "what is this?")
        #expect(bubble.images.map(\.name) == ["a.png", "b.jpg"])
        #expect(bubble.images.map(\.path) == ["/home/u/.hermes/images/upload_20261006_120000_1.png",
                                              "/home/u/.hermes/images/upload_20261006_120000_2.jpg"])
        #expect(bubble.images.allSatisfy { $0.localID != nil })
    }

    @Test func imageOnlyPromptSendsEmptyText() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        #expect(!composer.canSubmit)
        composer.attach(png("shot.png"))
        #expect(await eventually { composer.canSubmit })
        await composer.submit()
        #expect(log.requests("prompt.submit").first?["params"]?["text"] == "")
    }

    @Test func failedUploadDetachesEarlierImagesKeepsCardsAndRestoresTheDraft() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, params in
            method == "image.attach_bytes" && params["filename"] == "bad.png"
        }
        composer.attach(png("good.png"))
        composer.attach(png("bad.png"))
        composer.draft = "look"
        // Its early upload fails; the send tries it again.
        try await failNext("image.attach_bytes", where: { $0["params"]?["filename"] == "bad.png" }, in: log,
                           on: transport, code: 4018, message: "image too large (26214401 bytes; cap is 25 MB)")
        #expect(await eventually { composer.canSubmit })

        let sending = Task { await composer.submit() }
        #expect(await eventually { log.requests("image.attach_bytes").count == 3 })
        let retry = try #require(log.requests("image.attach_bytes").last)
        transport.respondError(to: retry, code: 4018, message: "image too large (26214401 bytes; cap is 25 MB)")
        await sending.value

        // good.png, queued when attached, is taken back off the queue.
        let good = "/home/u/.hermes/images/upload_20261006_120000_1.png"
        #expect(await eventually { !log.requests("image.detach").isEmpty })
        #expect(log.requests("image.detach").allSatisfy { $0["params"] == [
            "session_id": "sid-1", "profile": "coder", "path": .string(good)] })
        #expect(log.requests("prompt.submit").isEmpty)
        #expect(composer.attachments.map(\.filename) == ["good.png", "bad.png"])
        #expect(composer.draft == "look")
        #expect(composer.error == "Couldn't attach bad.png: image too large (26214401 bytes; cap is 25 MB)")
        #expect(composer.session.transcript.items.isEmpty)
    }

    @Test func removingACardKeepsItOffTheGateway() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        composer.attach(png("a.png"))
        let second = png("b.png")
        composer.attach(second)
        #expect(await eventually { composer.uploadingImageIDs.isEmpty })
        composer.removeAttachment(id: second.id)
        // Uploaded when attached, so taken back off the queue: it does not ride with the prompt.
        #expect(await eventually { log.requests("image.detach").count == 1 })
        #expect(log.requests("image.detach").first?["params"]?["path"]
                == "/home/u/.hermes/images/upload_20261006_120000_2.png")
        composer.draft = "hi"
        await composer.submit()
        #expect(log.requests("image.attach_bytes").count == 2)
        #expect(composer.session.transcript.items.last?.images.map(\.name) == ["a.png"])
    }

    @Test func rejectsImagesTheGatewayWouldRefuse() async throws {
        let (composer, _) = try await makeComposer(log: FrameLog())
        #expect(!composer.attach(ComposerAttachment(filename: "IMG_1.HEIC", data: Data([1]))))
        #expect(composer.error == "IMG_1.HEIC is not a PNG, JPEG, GIF or WebP image.")
        let huge = ComposerAttachment(filename: "big.png", data: Data(count: ImageAttachmentPolicy.maxBytes + 1))
        #expect(!composer.attach(huge))
        #expect(composer.error?.hasPrefix("big.png is too large") == true)
        #expect(composer.attachments.isEmpty)
    }

    @Test func imagesWhileATurnRunsGoOutAsAQueuedTurn() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        composer.draft = "first"
        await composer.submit()
        #expect(composer.session.transcript.isRunning)

        composer.attach(png("a.png"))
        composer.draft = "and this one"
        #expect(await eventually { composer.canSubmit })
        await composer.submit()

        let methods = log.all.compactMap { $0["method"]?.stringValue }.filter { $0 == "image.attach_bytes" || $0 == "prompt.submit" }
        #expect(methods == ["prompt.submit", "image.attach_bytes", "prompt.submit"])
        #expect(log.requests("prompt.submit").last?["params"]?["text"] == "and this one")
        #expect(composer.attachments.isEmpty)
        #expect(composer.draft.isEmpty)
        #expect(composer.error == nil)
    }

    @Test func sendingWithImagesWhileDisconnectedKeepsTheDraftAndSendsNothing() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        try await #require(connections.all.last).disconnect()
        let framesBefore = log.all.count

        composer.attach(png("a.png"))
        composer.draft = "x"
        #expect(await eventually { composer.failedImageUploads.count == 1 })
        await composer.submit()

        #expect(composer.draft == "x")
        #expect(composer.attachments.map(\.filename) == ["a.png"])
        #expect(composer.error == ComposerError.notConnected.message)
        #expect(log.all.count == framesBefore)
        #expect(composer.session.transcript.items.isEmpty)
    }

    private static let strandedPath = "/home/u/.hermes/images/upload_20261006_120000_1.png"

    /// a.png is queued on the server when attached; b.png's early upload fails, and the
    /// socket drops during the send's second try at it, so a.png's detach can't be
    /// sent: it is stranded. The second
    /// socket is the same backend with the runtime session still live (§7 fast
    /// reattach); `secondUnanswered` requests get no answer there.
    private func strandAnImage(secondLog: FrameLog, requestTimeout: Duration? = nil,
                               secondUnanswered: @escaping @Sendable (String) -> Bool = { _ in false })
        async throws -> (ChatComposer, GatewayConnection)
    {
        let log = FrameLog()
        let second = FakeTransport()
        let server = composerServer(confirmModel: false)
        second.serve(log: secondLog) { method, params in
            if secondUnanswered(method) { return nil }
            switch method {
            case "session.activate":
                return ["session_id": "sid-1", "session_key": "stored-new", "message_count": 0, "messages": [],
                        "info": ["model": "claude-opus-5-5"], "running": false, "status": "idle"]
            case "session.events.since":
                return ["events": [], "latest_seq": 1, "truncated": false, "count": 0, "epoch": "epoch-1",
                        "open_requests": []]
            // `session.resume` of a still-live session reuses its runtime id and its queue.
            case "session.resume":
                return ["session_id": "sid-1", "session_key": "stored-new", "resumed": "stored-new",
                        "message_count": 0, "messages": [], "info": ["model": "claude-opus-5-5"],
                        "running": false, "status": "idle"]
            default: return server(method, params)
            }
        }
        let (composer, first) = try await makeComposer(log: log, reconnectTo: [second],
                                                       requestTimeout: requestTimeout) { method, params in
            method == "image.attach_bytes" && params["filename"] == "b.png"
        }
        first.sendEvent("status.update", seq: 1, payload: ["kind": "status", "text": "ready"])
        #expect(await eventually { composer.session.lastSeq == 1 })
        composer.attach(png("a.png"))
        composer.attach(png("b.png"))
        composer.draft = "look"
        try await failNext("image.attach_bytes", where: { $0["params"]?["filename"] == "b.png" }, in: log,
                           on: first, code: 5000, message: "busy")
        #expect(await eventually { composer.canSubmit })

        let sending = Task { await composer.submit() }
        #expect(await eventually { log.requests("image.attach_bytes").count == 3 })
        first.serverDrops()
        await sending.value
        #expect(composer.draft == "look")
        #expect(composer.error?.hasPrefix("Couldn't attach b.png") == true)
        let connection = try #require(connections.all.last)
        #expect(await eventually { connection.state == .connected && !secondLog.requests("session.activate").isEmpty })
        return (composer, connection)
    }

    @Test func imagesStrandedByADropAreDetachedRightAfterTheReattach() async throws {
        let secondLog = FrameLog()
        let (composer, _) = try await strandAnImage(secondLog: secondLog)

        // Detached on the new socket without waiting for the next send.
        #expect(await eventually { secondLog.requests("image.detach").count == 1 })
        #expect(secondLog.requests("image.detach").first?["params"]?["path"] == .string(Self.strandedPath))
        #expect(await eventually { composer.session.strandedImagePaths.isEmpty })

        await composer.submit()
        let methods = secondLog.all.compactMap { $0["method"]?.stringValue }
            .filter { ["image.detach", "image.attach_bytes", "prompt.submit"].contains($0) }
        #expect(methods == ["image.detach", "image.attach_bytes", "image.attach_bytes", "prompt.submit"])
        #expect(composer.attachments.isEmpty)
    }

    @Test func strandedImagesSurviveReopeningTheChat() async throws {
        let secondLog = FrameLog()
        // The flush right after the reattach gets no answer (times out), so the
        // image is still stranded when the chat is reopened: only the reopened
        // chat's own send can detach it. The timeout covers every request, the
        // setup's too: 200 ms let a loaded run time out `session.create`.
        let detaches = Mutex(0)
        let (_, connection) = try await strandAnImage(secondLog: secondLog, requestTimeout: .seconds(2)) {
            $0 == "image.detach" && detaches.withLock { $0 += 1; return $0 } == 1
        }
        #expect(await eventually(seconds: 10) {
            secondLog.requests("image.detach").count == 1
                && connection.strandedImagePaths(sessionID: "sid-1") == [Self.strandedPath]
        })

        // Switching back to the chat makes a new ChatSession for the same runtime session.
        let reopened = try await connection.open(SessionSummary(id: "stored-new"))
        try await reopened.send("hi")

        let methods = secondLog.all.compactMap { $0["method"]?.stringValue }
            .filter { ["image.detach", "prompt.submit"].contains($0) }
        #expect(methods == ["image.detach", "image.detach", "prompt.submit"])
        #expect(secondLog.requests("image.detach").last?["params"]?["path"] == .string(Self.strandedPath))
        #expect(reopened.strandedImagePaths.isEmpty)
    }

    @Test func aSendDoesNotWaitForAnotherSessionsStrandedImages() async throws {
        let log = FrameLog()
        // sid-2's detach gets no answer on this live socket; it times out only
        // after the test.
        let (composer, _) = try await makeComposer(log: log, requestTimeout: .seconds(50)) { method, params in
            method == "image.detach" && params["path"] == "/p/other-session.png"
        }
        let connection = try #require(connections.all.last)
        connection.strand([
            StrandedImage(sessionID: "sid-2", profile: nil, path: "/p/other-session.png"),
            StrandedImage(sessionID: "sid-1", profile: "coder", path: "/p/this-session.png"),
        ])
        connection.flushStrandedImagesInBackground()
        // Establish that the other session really is awaiting an unanswered detach.
        #expect(await eventually { log.requests("image.detach").contains {
            $0["params"]?["path"] == "/p/other-session.png"
        } })

        try await composer.session.send("hi")
        // Sent while sid-2's flush still waits for its answer: a flush takes the
        // paths out and puts back the unanswered ones only when it ends.
        #expect(connection.strandedImagePaths(sessionID: "sid-2").isEmpty)
        #expect(connection.strandedImageFlushes["sid-2"] != nil)
        #expect(log.requests("prompt.submit").count == 1)
        #expect(log.requests("image.detach").contains { $0["params"]?["path"] == "/p/this-session.png" })
        #expect(composer.session.strandedImagePaths.isEmpty)
        await connection.disconnect()
    }

    @Test func aSendWaitingOnStrandedImagesCanBeCancelled() async throws {
        let log = FrameLog()
        // The detach gets no answer; it times out only after the test.
        let (composer, _) = try await makeComposer(log: log, requestTimeout: .seconds(50)) { method, _ in
            method == "image.detach"
        }
        let connection = try #require(connections.all.last)
        connection.strand([StrandedImage(sessionID: "sid-1", profile: "coder", path: "/p/stuck.png")])
        composer.attach(png("a.png"))
        composer.draft = "hi"
        #expect(await eventually { composer.canSubmit })

        let sending = Task { await composer.submit() }
        #expect(await eventually { composer.isSubmitting && !log.requests("image.detach").isEmpty })
        composer.cancelSubmit()
        await sending.value

        // Returned while the flush still waits for its answer (it puts the path back when it
        // ends). a.png, queued when attached, waits behind it to come off the queue too.
        #expect(connection.strandedImagePaths(sessionID: "sid-1") == ["/home/u/.hermes/images/upload_20261006_120000_1.png"])
        #expect(connection.strandedImageFlushes["sid-1"] != nil)
        #expect(!composer.isSubmitting)
        #expect(composer.draft == "hi")
        #expect(composer.attachments.map(\.filename) == ["a.png"])
        #expect(composer.error == nil)
        #expect(log.requests("image.attach_bytes").count == 1)
        #expect(log.requests("prompt.submit").isEmpty)
        #expect(composer.session.transcript.items.isEmpty)
        await connection.disconnect()
    }

    @Test func aSendWaitsUntilStrandedImagesAreGone() async throws {
        let secondLog = FrameLog()
        // On the new socket every image.detach goes unanswered (times out). The timeout
        // covers every request, the setup's too: 200 ms let a loaded run time out `session.create`.
        let (composer, _) = try await strandAnImage(secondLog: secondLog, requestTimeout: .seconds(2)) {
            $0 == "image.detach"
        }
        composer.draft = "look again"
        await composer.submit()

        #expect(secondLog.requests("image.attach_bytes").isEmpty)
        #expect(secondLog.requests("prompt.submit").isEmpty)
        #expect(composer.error == ComposerError.strandedImages.message)
        #expect(composer.draft == "look again")
        #expect(composer.attachments.map(\.filename) == ["a.png", "b.png"])
        #expect(composer.session.strandedImagePaths == [Self.strandedPath])

        // Text-only sends are held back the same way: the bubble goes, the draft comes back.
        composer.removeAttachment(id: composer.attachments[0].id)
        composer.removeAttachment(id: composer.attachments[0].id)
        await composer.submit()
        #expect(secondLog.requests("prompt.submit").isEmpty)
        #expect(composer.draft == "look again")
        #expect(composer.session.transcript.items.isEmpty)
    }

    @Test func strandedImagesAreCapped() async throws {
        let (composer, _) = try await makeComposer(log: FrameLog())
        let connection = try #require(connections.all.last)
        connection.strand((0..<60).map { StrandedImage(sessionID: "sid-1", profile: nil, path: "/p/\($0).png") })
        let kept = composer.session.strandedImagePaths
        #expect(kept.count == GatewayConnection.maxStrandedImages)
        #expect(kept.first == "/p/10.png")  // the oldest went first
        #expect(kept.last == "/p/59.png")
    }

    @Test func textTypedDuringAFailedImageSendIsKeptWithTheOriginal() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "image.attach_bytes" }
        composer.attach(png("big.png"))
        composer.draft = "describe this"
        try await failNext("image.attach_bytes", in: log, on: transport, code: 4018,
                           message: "image too large (26214401 bytes; cap is 25 MB)")
        #expect(await eventually { composer.canSubmit })
        let sending = Task { await composer.submit() }
        #expect(await eventually { log.requests("image.attach_bytes").count == 2 })
        composer.draft = "also"
        let retry = try #require(log.requests("image.attach_bytes").last)
        transport.respondError(to: retry, code: 4018, message: "image too large (26214401 bytes; cap is 25 MB)")
        await sending.value
        #expect(composer.draft == "describe this\nalso")
    }

    /// The cards leave the composer as the send starts (the prompt's bubble shows
    /// them), and come back if it fails.
    @Test func theCardsLeaveTheComposerWhenTheSendStartsAndComeBackIfItFails() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "prompt.submit" }
        let card = png("a.png")
        composer.attach(card)
        #expect(await eventually { composer.canSubmit })
        let sending = Task { await composer.submit() }
        #expect(await eventually { composer.isSubmitting && !log.requests("prompt.submit").isEmpty })
        #expect(composer.attachments.isEmpty)
        #expect(composer.session.transcript.items.last?.images.map(\.localID) == [card.id])
        // Nothing to remove while it is sending.
        composer.removeAttachment(id: card.id)
        try await failNext("prompt.submit", in: log, on: transport, code: 4001, message: "session not found")
        await sending.value
        #expect(composer.attachments.map(\.id) == [card.id])
    }

    @Test func capsTheNumberOfCards() async throws {
        let (composer, _) = try await makeComposer(log: FrameLog())
        for index in 0..<ImageAttachmentPolicy.maxAttachments { #expect(composer.attach(png("\(index).png"))) }
        #expect(!composer.attach(png("one-more.png")))
        #expect(composer.attachments.count == ImageAttachmentPolicy.maxAttachments)
        #expect(composer.error == "At most 10 images per message.")
    }

    // MARK: Model and effort

    @Test func loadsTheCatalogAndTheSessionsEffort() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        await composer.loadOptions()

        #expect(log.requests("model.options").first?["params"] == [
            "session_id": "sid-1", "profile": "coder", "explicit_only": true,
        ])
        #expect(log.requests("config.get").first?["params"] == [
            "key": "reasoning", "session_id": "sid-1", "profile": "coder",
        ])
        let catalog = try #require(composer.catalog)
        #expect(catalog.providers.map(\.slug) == ["anthropic", "openrouter"])  // no empty rows
        #expect(composer.currentModel == "claude-opus-5-5")
        #expect(composer.currentProvider == "anthropic")  // lazy info has none; the catalog's
        #expect(composer.currentModelLabel == "Opus 5.5")
        #expect(composer.currentEffort == "high")
        #expect(composer.effortChoices == ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
        #expect(composer.isCurrent(ModelChoice(provider: "anthropic", model: "claude-opus-5-5")))
        #expect(composer.error == nil)
    }

    /// A composer whose socket drops once `request` is waiting for its answer;
    /// the second socket resumes the same live session.
    private func dropDuring(_ request: String, _ action: @escaping @MainActor (ChatComposer) async -> Void)
        async throws -> ChatComposer
    {
        let log = FrameLog()
        let second = FakeTransport()
        let server = composerServer(confirmModel: false)
        second.serve(log: FrameLog()) { method, params in
            switch method {
            case "session.activate":
                return ["session_id": "sid-1", "session_key": "stored-new", "message_count": 0, "messages": [],
                        "info": ["model": "claude-opus-5-5"], "running": false, "status": "idle"]
            case "session.resume":
                return ["session_id": "sid-1", "session_key": "stored-new", "resumed": "stored-new",
                        "message_count": 0, "messages": [], "info": ["model": "claude-opus-5-5"],
                        "running": false, "status": "idle"]
            case "session.events.since":
                return ["events": [], "latest_seq": 1, "truncated": false, "count": 0, "epoch": "epoch-1",
                        "open_requests": []]
            case "commands.catalog": return ["pairs": []]
            default: return server(method, params)
            }
        }
        let (composer, first) = try await makeComposer(log: log, reconnectTo: [second]) { method, _ in
            method == request
        }
        first.sendEvent("status.update", seq: 1, payload: ["kind": "status", "text": "ready"])
        #expect(await eventually { composer.session.lastSeq == 1 })

        let acting = Task { await action(composer) }
        #expect(await eventually { !log.requests(request).isEmpty })
        first.serverDrops()
        await acting.value
        let connection = try #require(connections.all.last)
        #expect(await eventually { connection.state == .connected })
        return composer
    }

    /// The screen after a drop: "Couldn't load models" stayed under the composer
    /// although the reconnect loaded the models again.
    @Test func aModelLoadLostWithTheConnectionClearsOnReconnect() async throws {
        let composer = try await dropDuring("model.options") { await $0.loadOptions() }
        #expect(composer.error == "Couldn't load models: The connection to the gateway was lost.")

        await composer.loadCommandsAndOptions()  // what the composer runs on reconnecting
        #expect(composer.error == nil)
        #expect(composer.catalog != nil)
    }

    @Test func anEffortChangeLostWithTheConnectionClearsOnReconnect() async throws {
        let composer = try await dropDuring("config.set") { await $0.selectEffort("max") }
        #expect(composer.error == "Couldn't change the reasoning effort: The connection to the gateway was lost.")

        await composer.loadCommandsAndOptions()
        #expect(composer.error == nil)
    }

    /// A refusal is not the connection's doing: reloading the models keeps it.
    @Test func aRefusedEffortChangeStaysAfterTheModelsReload() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "config.set" }
        let changing = Task { await composer.selectEffort("max") }
        try await failNext("config.set", in: log, on: transport, code: 4001, message: "session not found")
        await changing.value
        await composer.loadOptions()
        #expect(composer.error == "Couldn't change the reasoning effort: session not found")
    }

    /// "Reload Models" that works takes away the earlier failure.
    @Test func aModelLoadThatWorksClearsTheEarlierFailure() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in
            method == "model.options" && log.requests("model.options").count == 1
        }
        let loading = Task { await composer.loadOptions() }
        try await failNext("model.options", in: log, on: transport, code: 5000, message: "inventory failed")
        await loading.value
        #expect(composer.error == "Couldn't load models: inventory failed")

        await composer.loadOptions()
        #expect(composer.error == nil)
        #expect(composer.catalog != nil)
    }

    @Test func switchesTheModelForThisSessionOnly() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        await composer.loadOptions()

        await composer.selectModel(ModelChoice(provider: "openrouter", model: "deepseek/deepseek-v4"))

        #expect(log.requests("config.set").first?["params"] == [
            "key": "model", "value": "deepseek/deepseek-v4 --provider openrouter --session",
            "session_id": "sid-1", "profile": "coder",
        ])
        #expect(composer.currentModel == "deepseek/deepseek-v4")
        #expect(composer.currentProvider == "openrouter")
        // A reasoning-mandatory model offers no "Off".
        #expect(composer.effortChoices.first == "minimal")
        #expect(composer.error == nil)

        // The gateway's own session.info stays authoritative.
        composer.session.apply(GatewayEvent(type: "session.info", sessionID: "sid-1",
                                            payload: ["model": "claude-haiku-4-5-20251001", "provider": "anthropic",
                                                      "reasoning_effort": "low"]))
        #expect(composer.currentModelLabel == "Haiku 4.5")
        #expect(composer.effortChoices.isEmpty)  // no reasoning control: picker hidden
    }

    @Test func expensiveModelNeedsConfirmationBeforeItApplies() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log, confirmModel: true)
        await composer.loadOptions()
        let haiku = ModelChoice(provider: "anthropic", model: "claude-haiku-4-5-20251001")

        await composer.selectModel(haiku)
        #expect(composer.pendingModelSwitch?.message == "Opus is expensive")
        #expect(composer.currentModel == "claude-opus-5-5")  // nothing applied yet

        await composer.confirmPendingModelSwitch()
        let sets = log.requests("config.set").map { $0["params"] }
        #expect(sets.count == 2)
        #expect(sets.last??["confirm_expensive_model"] == true)
        #expect(composer.pendingModelSwitch == nil)
        #expect(composer.currentModel == "claude-haiku-4-5-20251001")
    }

    @Test func changesTheEffortForThisSession() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        await composer.loadOptions()
        await composer.selectEffort("low")
        #expect(log.requests("config.set").first?["params"] == [
            "key": "reasoning", "value": "low", "session_id": "sid-1", "profile": "coder",
        ])
        #expect(log.requests("config.set").first?["params"]?["scope"] == nil)  // never global
        #expect(composer.currentEffort == "low")
    }

    @Test func effortFailureShowsInTheComposerAndKeepsTheOldValue() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "config.set" }
        await composer.loadOptions()

        let changing = Task { await composer.selectEffort("max") }
        // A reaped runtime id answers 4001 rather than writing the profile config
        // (`methods_config_set.py:482-494`).
        try await failNext("config.set", in: log, on: transport, code: 4001, message: "session not found")
        await changing.value

        #expect(composer.error == "Couldn't change the reasoning effort: session not found")
        #expect(composer.currentEffort == "high")
    }

    @Test func failedSubmitShowsOnTheTranscriptAndDetachesTheImages() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "prompt.submit" }
        composer.attach(png("a.png"))
        composer.draft = "hi"

        let sending = Task { await composer.submit() }
        let limit = "Hermes is at the active session limit (4/4). Try again when another session finishes."
        try await failNext("prompt.submit", in: log, on: transport, code: 4090, message: limit)
        await sending.value

        #expect(composer.session.transcript.lastError == limit)
        #expect(composer.error == nil)
        #expect(log.requests("image.detach").count == 1)
        #expect(composer.attachments.map(\.filename) == ["a.png"])  // kept for a retry
        #expect(composer.draft == "hi")  // and the text with them
    }

    @Test func deferredModelSwitchShowsThePick() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log, deferModel: true)
        await composer.loadOptions()
        let deepseek = ModelChoice(provider: "openrouter", model: "deepseek/deepseek-v4")
        await composer.selectModel(deepseek)
        #expect(composer.currentModel == "deepseek/deepseek-v4")
        #expect(composer.pendingModelSwitch == nil)
        #expect(composer.error == nil)
    }

    /// The chat runs X (`claude-opus-5-5`). Picks A, then B. Answers arrive in
    /// order, as the gateway runs `config.set` in arrival order: A succeeds,
    /// then B gets `answerB`.
    private func pickTwiceWhereTheSecondDoesNotApply(log: FrameLog, composer: ChatComposer, transport: FakeTransport,
                                                     answerB: (JSONValue) -> Void) async throws {
        await composer.loadOptions()
        #expect(composer.currentModel == "claude-opus-5-5")
        let modelA = ModelChoice(provider: "anthropic", model: "claude-haiku-4-5-20251001")
        let modelB = ModelChoice(provider: "openrouter", model: "deepseek/deepseek-v4")
        let pickA = Task { await composer.selectModel(modelA) }
        #expect(await eventually { log.requests("config.set").count == 1 })
        let pickB = Task { await composer.selectModel(modelB) }
        #expect(await eventually { log.requests("config.set").count == 2 })
        let requests = log.requests("config.set")
        transport.respond(to: requests[0], result: ["key": "model", "value": .string(modelA.model), "warning": "",
                                                    "confirm_required": false, "confirm_message": "", "scope": "session"])
        await pickA.value
        answerB(requests[1])
        await pickB.value
    }

    @Test func anEarlierAppliedPickStaysShownWhenTheNewestNeedsConfirmationAndIsCancelled() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "config.set" }
        try await pickTwiceWhereTheSecondDoesNotApply(log: log, composer: composer, transport: transport) { request in
            transport.respond(to: request, result: ["key": "model", "value": "deepseek/deepseek-v4",
                                                    "warning": "DeepSeek is expensive", "confirm_required": true,
                                                    "confirm_message": "DeepSeek is expensive", "scope": "session"])
        }
        #expect(composer.pendingModelSwitch?.choice.model == "deepseek/deepseek-v4")
        composer.cancelPendingModelSwitch()
        #expect(composer.currentModel == "claude-haiku-4-5-20251001")
        #expect(composer.currentProvider == "anthropic")
    }

    @Test func anEarlierAppliedPickStaysShownWhenTheNewestFails() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "config.set" }
        try await pickTwiceWhereTheSecondDoesNotApply(log: log, composer: composer, transport: transport) { request in
            transport.respondError(to: request, code: 4001, message: "session not found")
        }
        #expect(composer.currentModel == "claude-haiku-4-5-20251001")
        #expect(composer.error == "Couldn't switch the model: session not found")
    }

    @Test func theLastModelPickWinsWhenAnswersArriveOutOfOrder() async throws {
        let log = FrameLog()
        let (composer, transport) = try await makeComposer(log: log) { method, _ in method == "config.set" }
        await composer.loadOptions()
        let haiku = ModelChoice(provider: "anthropic", model: "claude-haiku-4-5-20251001")
        let deepseek = ModelChoice(provider: "openrouter", model: "deepseek/deepseek-v4")

        let firstPick = Task { await composer.selectModel(haiku) }
        #expect(await eventually { log.requests("config.set").count == 1 })
        let secondPick = Task { await composer.selectModel(deepseek) }
        #expect(await eventually { log.requests("config.set").count == 2 })
        let requests = log.requests("config.set")
        func answer(_ request: JSONValue, model: String) {
            transport.respond(to: request, result: ["key": "model", "value": .string(model), "warning": "",
                                                    "confirm_required": false, "confirm_message": "", "scope": "session"])
        }
        answer(requests[1], model: deepseek.model)
        await secondPick.value
        answer(requests[0], model: haiku.model)
        await firstPick.value

        #expect(composer.currentModel == "deepseek/deepseek-v4")
        #expect(composer.currentProvider == "openrouter")
    }

    @Test func effortWordsOutsideTheLevelsAreNeverSent() async throws {
        let log = FrameLog()
        let (composer, _) = try await makeComposer(log: log)
        for word in ["off", "on", "show", "hide", "full", "clamp", "High", ""] {
            await #expect(throws: ComposerError.unsupportedEffort(word)) {
                try await composer.session.setReasoningEffort(word)
            }
        }
        await composer.selectEffort("off")
        #expect(composer.error == "\"off\" is not a reasoning effort level.")
        #expect(log.requests("config.set").isEmpty)
    }
}

@Suite struct ModelSwitchTests {
    @Test func sessionValue() {
        #expect(ModelSwitch.sessionValue(model: "m", provider: "p") == "m --provider p --session")
        #expect(ModelSwitch.sessionValue(model: " m ", provider: "  ") == "m --session")
        #expect(ModelSwitch.sessionValue(model: "m", provider: "") == "m --session")
    }
}

@Suite struct ImageEncodePlanTests {
    private typealias Attempt = ImageAttachmentPolicy.EncodeAttempt
    private let cap = ImageAttachmentPolicy.maxBytes

    @Test func sourceUnderTheCapWhoseOutputMayNotBe() {
        // A 20 MB, 9000×9000 TIFF with alpha: native PNG first, then smaller, then JPEG.
        #expect(ImageAttachmentPolicy.encodeAttempts(sourceBytes: 20_000_000, pixelWidth: 9000, pixelHeight: 9000,
                                                     hasAlpha: true) == [
            Attempt(maxPixels: nil, format: .png),
            Attempt(maxPixels: 4096, format: .png), Attempt(maxPixels: 4096, format: .jpeg),
            Attempt(maxPixels: 2048, format: .png), Attempt(maxPixels: 2048, format: .jpeg),
        ])
    }

    @Test func sourceOverTheCapStartsScaledDown() {
        #expect(ImageAttachmentPolicy.encodeAttempts(sourceBytes: cap + 1, pixelWidth: 8000, pixelHeight: 6000,
                                                     hasAlpha: false) == [
            Attempt(maxPixels: 4096, format: .jpeg), Attempt(maxPixels: 2048, format: .jpeg),
        ])
        #expect(ImageAttachmentPolicy.encodeAttempts(sourceBytes: cap + 1, pixelWidth: 3000, pixelHeight: 1000,
                                                     hasAlpha: false) == [Attempt(maxPixels: 2048, format: .jpeg)])
    }

    @Test func unknownDimensionsNeverShrinkToAPixel() {
        let attempts = ImageAttachmentPolicy.encodeAttempts(sourceBytes: 1000, pixelWidth: nil, pixelHeight: nil,
                                                            hasAlpha: false)
        #expect(attempts == [Attempt(maxPixels: nil, format: .jpeg), Attempt(maxPixels: 4096, format: .jpeg),
                             Attempt(maxPixels: 2048, format: .jpeg)])
        #expect(ImageAttachmentPolicy.encodeAttempts(sourceBytes: cap + 1, pixelWidth: 0, pixelHeight: nil,
                                                     hasAlpha: true).allSatisfy { ($0.maxPixels ?? .max) >= 2048 })
    }

    @Test func smallImagesKeepTheirSize() {
        #expect(ImageAttachmentPolicy.encodeAttempts(sourceBytes: 50_000, pixelWidth: 800, pixelHeight: 600,
                                                     hasAlpha: true) == [
            Attempt(maxPixels: nil, format: .png), Attempt(maxPixels: nil, format: .jpeg),
        ])
        // A small image whose source is over the cap (a long animated GIF): one JPEG frame.
        #expect(ImageAttachmentPolicy.encodeAttempts(sourceBytes: cap + 1, pixelWidth: 480, pixelHeight: 270,
                                                     hasAlpha: false) == [Attempt(maxPixels: nil, format: .jpeg)])
    }
}

@Suite struct ModelLabelTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("anthropic/claude-sonnet-5-5[1m]", "Sonnet 5.5 · 1M"),
        ("gpt-5.2", "GPT-5.2"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("deepseek/deepseek-v4-flash", "DeepSeek V4 · Flash"),
        ("qwen3-235b-a22b", "Qwen3 235B A22B"),
        ("", "No model"),
    ])
    func displayName(model: String, expected: String) {
        #expect(ModelLabel.displayName(model) == expected)
    }
}

@Suite struct ReasoningEffortTests {
    @Test func choicesFollowTheModelsCapabilities() {
        let all = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        #expect(ReasoningEffort.choices(for: nil) == all)
        #expect(ReasoningEffort.choices(for: ModelCapabilities(reasoning: true)) == all)
        #expect(ReasoningEffort.choices(for: ModelCapabilities(reasoning: true, canDisableReasoning: false))
            == Array(all.dropFirst()))
        #expect(ReasoningEffort.choices(for: ModelCapabilities(reasoning: false)).isEmpty)
    }

    @Test func labels() {
        #expect(ReasoningEffort.label("xhigh") == "Extra High")
        #expect(ReasoningEffort.label("none") == "Off")
        #expect(ReasoningEffort.normalized(" High ") == "high")
        #expect(ReasoningEffort.normalized("") == nil)
    }
}

@Suite struct ImageAttachmentPolicyTests {
    @Test func renamesReencodedCopies() {
        #expect(ImageAttachmentPolicy.filename("IMG_0001.HEIC", withExtension: "jpg") == "IMG_0001.jpg")
        #expect(ImageAttachmentPolicy.filename("scan", withExtension: "png") == "scan.png")
        #expect(ImageAttachmentPolicy.filename("", withExtension: "png") == "image.png")
        #expect(ImageAttachmentPolicy.filename(".hidden", withExtension: "png") == ".hidden.png")
    }

    @Test func passesThroughWhatVisionProvidersRead() {
        #expect(ImageAttachmentPolicy.canSendUnchanged(filename: "a.PNG"))
        #expect(ImageAttachmentPolicy.canSendUnchanged(filename: "a.webp"))
        #expect(!ImageAttachmentPolicy.canSendUnchanged(filename: "a.heic"))
        #expect(!ImageAttachmentPolicy.canSendUnchanged(filename: "a.tiff"))
        #expect(!ImageAttachmentPolicy.canSendUnchanged(filename: "noext"))
    }

    @Test func cardDetailLine() {
        let card = ComposerAttachment(filename: "a.png", data: Data(count: 2_400_000), pixelWidth: 1920, pixelHeight: 1080)
        #expect(card.detail == "1920×1080 · 2.4 MB")
        #expect(ComposerAttachment(filename: "a.png", data: Data(count: 14_200)).detail == "14 KB")
        #expect(ComposerAttachment(filename: "a.png", data: Data(count: 3), source: "~/Desktop/a.png").detail
            == "~/Desktop/a.png")
    }
}
