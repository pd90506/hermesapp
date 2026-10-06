import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// The composer's sends during a reply, through the paging transcript's bubble lifecycle
// (docs/protocol.md §4.1, §10.3): the bubble shows at once, is marked answered with the
// `prompt.submit` status, and goes once quiet re-reads show the stored rows.

private func user(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "user", content: .string(text))
}

private func assistant(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "assistant", content: .string(text))
}

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

/// How many times an image named `name` shows (a bubble's local upload, or a stored
/// row's `@image:` file).
private func pictures(_ transcript: Transcript, _ name: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.images.filter { $0.name == name }.count }
}

private let storedUpload = "upload_20261006_120000_2.png"

private let idleRows = (1...300).map { storedRow(id: $0) }

private let runningRows = (1...289).map { storedRow(id: $0) } + [user(290, "查一下"), assistant(291, "我先看一下文件")]

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerPagingTests {
    /// A chat opened while `查一下` runs (or, `running: false`, a cold-opened idle chat
    /// with 300 stored rows), with a composer.
    private func open(running: Bool = true) async throws
        -> (ChatComposer, FakeTransport, PagedServer, FrameLog, GatewayConnection)
    {
        let server = PagedServer(store: FakeMessageStore(rows: running ? runningRows : idleRows))
        if running {
            server.runningTurn.withLock { $0 = ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"] }
        }
        let log = FrameLog()
        let (connection, transport) = try await server.connect(log: log)
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        return (ChatComposer(session: session), transport, server, log, connection)
    }

    private func settled(_ session: ChatSession) -> Bool {
        !session.transcript.isRunning && session.rereadTask == nil && !session.transcript.needsReread
            && session.transcript.historyCount == session.transcript.items.count
    }

    /// Text sent from the composer while the reply streams, answered `redirected` (the
    /// default `busy_input_mode`, `tui_gateway/server.py:375-377`): Hermes stores the
    /// partial reply, the correction and the new reply (`agent/interrupt_control.py:261-305`).
    @Test func composerTextRedirectingAReplySettlesToOneCopyOfEachText() async throws {
        let (composer, transport, server, log, connection) = try await open()
        let session = composer.session
        #expect(session.transcript.isRunning)
        server.busyStatus.withLock { $0 = "redirected" }

        composer.draft = "换个思路"
        #expect(composer.canSubmit)
        await composer.submit()
        #expect(composer.draft.isEmpty && composer.error == nil)
        #expect(log.requests("prompt.submit").last?["params"]?["text"] == "换个思路")
        #expect(occurrences(session.transcript, "换个思路") == 1)

        server.store.append([assistant(292, "部分"), user(293, "换个思路"), assistant(294, "新的结果")])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "新的结果"])
        #expect(await eventually { occurrences(session.transcript, "新的结果") == 1 })
        #expect(occurrences(session.transcript, "换个思路") >= 1)
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: completePayload("新的结果", rows: [290, 291, 292, 294]))

        #expect(await eventually { settled(session) })
        for text in ["查一下", "我先看一下文件", "部分", "换个思路", "新的结果"] {
            #expect(occurrences(session.transcript, text) == 1, "\(text)")
        }
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// An image prompt sent while the reply streams is queued as its own turn
    /// (`session_auto_continue.py:414-448`). Its bubble (`[Image: …]`) differs from the
    /// stored row (`@image:` refs, `session_history.py:51-60`); it still settles, by the
    /// quiet re-reads, to the stored rows alone.
    @Test func composerImageQueuedDuringAReplySettlesToTheStoredRows() async throws {
        let (composer, transport, server, log, connection) = try await open()
        let session = composer.session
        server.busyStatus.withLock { $0 = "queued" }

        composer.attach(ComposerAttachment(filename: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47])))
        composer.draft = "看这张图"
        await composer.submit()
        let methods = log.all.compactMap { $0["method"]?.stringValue }.filter { $0 == "image.attach_bytes" || $0 == "prompt.submit" }
        #expect(methods == ["image.attach_bytes", "prompt.submit"])
        #expect(composer.attachments.isEmpty && composer.error == nil)
        #expect(pictures(session.transcript, "a.png") == 1)

        // Accept-time row, then the running reply ends.
        let stored = "看这张图\n@image:/home/u/.hermes/images/upload_20261006_120000_2.png"
        server.store.append([user(292, stored), assistant(293, "结果显示4")])
        var seq = 0
        func event(_ type: String, _ payload: JSONValue? = nil) {
            seq += 1
            transport.sendEvent(type, sessionID: session.sessionID, seq: seq, payload: payload)
        }
        event("message.delta", ["text": "结果显示4"])
        event("message.complete", completePayload("结果显示4", rows: [290, 291, 293]))
        #expect(await eventually { !session.transcript.isRunning && session.rereadTask == nil })
        #expect(occurrences(session.transcript, "看这张图") >= 1)  // never missing

        // The queued turn runs: its accept row is re-placed at the end (`session_auto_continue.py:348-395`).
        server.store.remove(id: 292)
        server.store.append([user(294, stored), assistant(295, "图里是一只猫")])
        event("message.start")
        #expect(occurrences(session.transcript, "看这张图") >= 1)
        event("message.delta", ["text": "图里是一只猫"])
        #expect(await eventually { session.transcript.isRunning && occurrences(session.transcript, "图里是一只猫") == 1 })
        #expect(occurrences(session.transcript, "看这张图") >= 1)
        event("message.complete", completePayload("图里是一只猫", rows: [294, 295]))

        #expect(await eventually { settled(session) })
        #expect(pictures(session.transcript, "a.png") == 0)  // the bubble went
        #expect(pictures(session.transcript, storedUpload) == 1)  // the stored row's image
        #expect(occurrences(session.transcript, "@image:") == 0)
        for text in ["查一下", "结果显示4", "看这张图", "图里是一只猫"] {
            #expect(occurrences(session.transcript, text) == 1, "\(text): \(session.transcript.items.suffix(6).map(\.text))")
        }
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// An image-only prompt submits `text: ""`: no row at submit, and `streaming` with no
    /// `user_row_id` (`session_workdir.py:621`, `methods_prompt.py:815-820`). Its turn can
    /// start long after any quiet re-read (agent build after a deferred history,
    /// `server.py:1164`). The bubble must stay until that turn has stored the row.
    @Test func anImageOnlyPromptKeepsItsBubbleUntilItsTurnStoresTheRow() async throws {
        let (composer, transport, server, log, connection) = try await open(running: false)
        let session = composer.session
        #expect(!session.transcript.isRunning)

        composer.attach(ComposerAttachment(filename: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47])))
        await composer.submit()
        #expect(log.requests("prompt.submit").last?["params"]?["text"] == "")
        #expect(composer.attachments.isEmpty && composer.error == nil)

        // Every re-read the answer could set off has landed; the turn has not started.
        await settle(session)
        #expect(await eventually { session.rereadTask == nil && !session.transcript.needsReread })
        #expect(pictures(session.transcript, "a.png") == 1)

        var seq = 0
        func event(_ type: String, _ payload: JSONValue? = nil) {
            seq += 1
            transport.sendEvent(type, sessionID: session.sessionID, seq: seq, payload: payload)
        }
        event("message.start")
        server.store.append([user(301, "@image:/home/u/.hermes/images/upload_20261006_120000_2.png"),
                             assistant(302, "一只猫")])
        event("message.delta", ["text": "一只猫"])
        #expect(await eventually { occurrences(session.transcript, "一只猫") == 1 })
        #expect(pictures(session.transcript, "a.png") == 1)
        event("message.complete", completePayload("一只猫", rows: [301, 302]))

        #expect(await eventually { settled(session) })
        #expect(pictures(session.transcript, "a.png") == 0)
        #expect(pictures(session.transcript, storedUpload) == 1)
        #expect(occurrences(session.transcript, "@image:") == 0)
        #expect(occurrences(session.transcript, "一只猫") == 1)
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// A failed image submit: the bubble stays (only it holds the prompt) as a *failed*
    /// one, nothing spins in an idle chat, and the draft and cards come back. A failed
    /// bubble no longer counts as unanswered, so a later prompt still settles.
    @Test func aFailedImageSubmitKeepsItsBubbleAndRestoresTheComposer() async throws {
        let (composer, transport, server, log, connection) = try await open(running: false)
        let session = composer.session
        server.holdSubmits.withLock { $0 = true }
        composer.attach(ComposerAttachment(filename: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47])))
        composer.draft = "看图"

        let sending = Task { await composer.submit() }
        #expect(await eventually { !log.requests("prompt.submit").isEmpty })
        let limit = "Hermes is at the active session limit (4/4). Try again when another session finishes."
        transport.respondError(to: try #require(log.requests("prompt.submit").last), code: 4090, message: limit)
        await sending.value

        #expect(session.transcript.items.contains { $0.text == "看图" && $0.images.map(\.name) == ["a.png"] })
        #expect(!session.transcript.isRunning)
        #expect(session.transcript.lastError == limit)
        #expect(composer.draft == "看图")
        #expect(composer.attachments.map(\.filename) == ["a.png"])
        #expect(log.requests("image.detach").count == 1)

        server.holdSubmits.withLock { $0 = false }
        composer.removeAttachment(id: composer.attachments[0].id)
        composer.draft = "再试一次"
        await composer.submit()
        await settle(session)
        #expect(await eventually { session.rereadTask == nil && !session.transcript.needsReread })
        #expect(occurrences(session.transcript, "再试一次") == 1)
        #expect(pictures(session.transcript, "a.png") == 1)  // the failed bubble stays
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }
}
