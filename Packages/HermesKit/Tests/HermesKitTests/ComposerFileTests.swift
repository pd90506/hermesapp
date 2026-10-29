import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

/// `file.attach` success for uploaded bytes (`methods_prompt.py:975-995`).
private func fileAttached(name: String) -> JSONValue {
    ["attached": true, "name": .string(name), "path": .string("/srv/hermes/attachments/\(name)"),
     "ref_path": .string("attachments/\(name)"), "ref_text": .string("@file:attachments/\(name)"), "uploaded": true]
}

/// `image.attach_bytes` success (`methods_prompt.py:886-914`, image meta `server.py:861-870`).
private func imageAttached(path: String) -> JSONValue {
    ["attached": true, "path": .string(path), "count": 1, "remainder": "", "text": "[User attached image: a.png]",
     "bytes": 4, "name": "a.png"]
}

private let png = Data([0x89, 0x50, 0x4E, 0x47])
private let pdf = Data("%PDF-1.7".utf8)

/// Files in the composer: uploaded when attached (`file.attach`), sent as leading
/// `@file:` references (`docs/protocol.md` §10.5).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerFileTests {
    /// `ChatSession.connection` is weak: the test owns the connection.
    private let connections = ConnectionKeeper()

    private func openComposer(_ gateway: ScriptedGateway) async throws -> ChatComposer {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return connection.composer(for: try await connection.newSession())
    }

    @Test func filesUploadWhenAttachedAndGoInFrontOfTheText() async throws {
        let gateway = ScriptedGateway()
        gateway.on("file.attach") { params in .result(fileAttached(name: params["name"]?.stringValue ?? "")) }
        gateway.on("image.attach_bytes", result: imageAttached(path: "/srv/hermes/images/upload_1.png"))
        let composer = try await openComposer(gateway)

        #expect(await composer.attachFile(pdf, filename: "report.pdf", mimeType: "application/pdf"))
        // Uploaded at once, like images (`ChatComposer.attach`).
        #expect(gateway.params("file.attach") == [[
            "session_id": "sid-1", "name": "report.pdf",
            "data_url": .string("data:application/pdf;base64," + pdf.base64EncodedString()),
        ]])
        #expect(composer.files.map(\.refText) == ["@file:attachments/report.pdf"])
        #expect(composer.attach(ComposerAttachment(filename: "shot.png", data: png)))
        composer.draft = "Summarise these"
        #expect(await eventually { composer.canSubmit })

        await composer.submit()

        #expect(gateway.params("image.attach_bytes").count == 1)
        #expect(gateway.params("prompt.submit") == [[
            "session_id": "sid-1", "text": "@file:attachments/report.pdf\n\nSummarise these",
        ]])
        #expect(composer.files.isEmpty && composer.attachments.isEmpty && composer.error == nil)
        let bubble = try #require(composer.session.transcript.items.last)
        #expect(bubble.text == "Summarise these" && bubble.attachments == ["report.pdf"] && bubble.images.count == 1)
        #expect(bubble.attachmentPaths == ["attachments/report.pdf"])
    }

    @Test func aFileAloneIsSentAsItsReference() async throws {
        let gateway = ScriptedGateway()
        gateway.on("file.attach") { params in .result(fileAttached(name: params["name"]?.stringValue ?? "")) }
        let composer = try await openComposer(gateway)

        await composer.attachFile(Data("a,b\n".utf8), filename: "data.csv")
        await composer.submit()

        #expect(gateway.params("prompt.submit") == [["session_id": "sid-1", "text": "@file:attachments/data.csv"]])
        #expect(gateway.params("file.attach").first?["data_url"]?.stringValue?.hasPrefix(
            "data:application/octet-stream;base64,") == true)
        #expect(composer.session.transcript.items.last?.attachments == ["data.csv"])
    }

    /// An image Hermes takes unchanged becomes an image card, uploaded on send.
    @Test func imageFilesBecomeImageCards() async throws {
        let gateway = ScriptedGateway()
        let composer = try await openComposer(gateway)

        #expect(await composer.attachFile(png, filename: "Photo.PNG"))

        #expect(composer.attachments.map(\.filename) == ["Photo.PNG"] && composer.files.isEmpty)
        #expect(gateway.params("file.attach").isEmpty)
    }

    /// `file.attach` failures are JSON-RPC errors, 5028 for a staging failure
    /// (`methods_prompt.py:994-995`); an empty file is refused before any call.
    @Test func refusedFilesAreReportedInTheComposer() async throws {
        let gateway = ScriptedGateway()
        gateway.on("file.attach") { _ in .error(code: 5028, message: "disk full") }
        let composer = try await openComposer(gateway)

        #expect(await composer.attachFile(pdf, filename: "report.pdf") == false)
        #expect(composer.error == "Couldn't attach report.pdf: disk full" && composer.files.isEmpty)

        #expect(await composer.attachFile(Data(), filename: "empty.txt") == false)
        #expect(composer.error == "Couldn't attach empty.txt: the file is empty")
        #expect(gateway.params("file.attach").count == 1)
    }

    /// Like images: a failed send keeps the cards and gives the text back.
    @Test func aFailedSendKeepsTheFilesAndTheText() async throws {
        let gateway = ScriptedGateway()
        gateway.on("file.attach") { params in .result(fileAttached(name: params["name"]?.stringValue ?? "")) }
        gateway.on("prompt.submit") { _ in .error(code: 4009, message: "session busy") }
        let composer = try await openComposer(gateway)
        await composer.attachFile(pdf, filename: "report.pdf")
        composer.draft = "read it"

        await composer.submit()

        #expect(composer.files.map(\.name) == ["report.pdf"])
        #expect(composer.draft == "read it")
        #expect(composer.session.transcript.lastError == "session busy")
        let removed = try #require(composer.files.first)
        composer.removeAttachment(id: removed.id)
        #expect(composer.files.isEmpty)
    }

    /// The retry of a failed send with files resumes a reclaimed chat, which rebuilds
    /// the transcript: the failed bubble's text is not given back a second time (the
    /// composer already holds it with the cards).
    @Test func aRebuildDoesNotGiveAFailedFileSendsTextBackTwice() async throws {
        let gateway = ScriptedGateway()
        gateway.on("file.attach") { params in .result(fileAttached(name: params["name"]?.stringValue ?? "")) }
        gateway.on("prompt.submit") { _ in .error(code: 4009, message: "session busy") }
        let composer = try await openComposer(gateway)
        await composer.attachFile(pdf, filename: "report.pdf")
        composer.draft = "read it"
        await composer.submit()
        #expect(composer.draft == "read it")

        gateway.on("session.resume") { _ in .result(resumedPayload(sid: "sid-2", key: "stored-1")) }
        gateway.on("prompt.submit", result: ["status": "streaming"])
        gateway.transport.sendEvent("session.reclaimed", sessionID: "",
                                    payload: ["session_id": "sid-1", "stored_session_id": "stored-1",
                                              "reason": "idle_timeout"])
        #expect(await eventually { composer.session.isRuntimeGone })
        await composer.submit()

        #expect(gateway.params("prompt.submit").last == ["session_id": "sid-2",
                                                         "text": "@file:attachments/report.pdf\n\nread it"])
        #expect(composer.draft.isEmpty && composer.files.isEmpty)
    }
}

/// `session.steer`, `session.redirect`, `/btw` (`docs/protocol.md` §10.7).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SteeringTests {
    private let connections = ConnectionKeeper()

    private func openChat(_ gateway: ScriptedGateway) async throws -> ChatSession {
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        return try await connection.newSession()
    }

    @Test func steerInjectsIntoTheRunningTurn() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.steer") { params in .result(["status": "queued", "text": params["text"] ?? ""]) }
        let session = try await openChat(gateway)
        try await session.send("long task")

        let outcome = try await session.steer("use the staging db")

        #expect(outcome == .steered)
        #expect(gateway.params("session.steer") == [["session_id": "sid-1", "text": "use the staging db"]])
        #expect(session.transcript.items.last?.isSteer == true)
        #expect(gateway.params("prompt.submit").count == 1)
        expectWellFormed(session.transcript)
    }

    /// `session.steer` on an idle session answers `rejected` (`methods_session.py:2474-2477`).
    @Test func steerWithNoTurnRunningSendsAPrompt() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.steer") { params in .result(["status": "rejected", "text": params["text"] ?? ""]) }
        let session = try await openChat(gateway)

        let outcome = try await session.steer("hello")

        #expect(outcome == .sentAsPrompt)
        #expect(gateway.params("prompt.submit") == [["session_id": "sid-1", "text": "hello"]])
        #expect(session.transcript.items.last?.isSteer == false)
    }

    /// A redirect is a plain user row (not a steer) below the reply so far
    /// (`use-prompt-actions/index.ts:817-852`). Text the old call still streams joins the
    /// reply above it; the corrected call's text, which starts with a paragraph break
    /// (`stream_delivery.py:305-310`), goes below.
    @Test func redirectIsWhatEnterDoesWhileBusy() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.redirect") { params in .result(["status": "redirected", "text": params["text"] ?? ""]) }
        let session = try await openChat(gateway)
        try await session.send("write a long essay")
        gateway.transport.sendEvent("message.delta", payload: ["text": "Once upon"])
        #expect(await eventually { session.transcript.items.last?.text == "Once upon" })

        #expect(try await session.redirect("actually, stop and summarise") == .redirected)
        gateway.transport.sendEvent("message.delta", payload: ["text": " a time"])
        gateway.transport.sendEvent("message.delta", payload: ["text": "\n\nSummary."])

        #expect(gateway.params("session.redirect") == [["session_id": "sid-1", "text": "actually, stop and summarise"]])
        #expect(await eventually { session.transcript.items.last?.text == "\n\nSummary." })
        let texts = session.transcript.items.map(\.text)
        #expect(texts == ["write a long essay", "Once upon a time", "actually, stop and summarise", "\n\nSummary."])
        #expect(!session.transcript.items[2].isSteer && !session.transcript.items[1].isActive)
        expectWellFormed(session.transcript)
    }

    /// While the turn is still being set up a redirect is queued as the next turn
    /// (`methods_session.py:2453-2457`): its row goes to the end (`index.ts:854-860`).
    @Test func aQueuedRedirectBecomesTheNextTurn() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.redirect") { params in .result(["status": "queued", "text": params["text"] ?? ""]) }
        let session = try await openChat(gateway)
        try await session.send("go")

        #expect(try await session.redirect("then do this") == .queuedForNextTurn)
        #expect(session.transcript.items.last?.text == "then do this")
        #expect(session.transcript.items.last?.isSteer == false)
    }

    /// A failed redirect withdraws its row; `rejected` (no turn running) sends the
    /// text as a normal prompt instead.
    @Test func aFailedOrRejectedRedirectWithdrawsItsRow() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.redirect") { _ in .error(code: 4010, message: "agent does not support active-turn redirect") }
        let session = try await openChat(gateway)

        await #expect(throws: RPCError.self) { try await session.redirect("hi") }
        #expect(session.transcript.items.isEmpty && !session.transcript.isRunning)

        gateway.on("session.redirect") { params in .result(["status": "rejected", "text": params["text"] ?? ""]) }
        #expect(try await session.redirect("hi") == .sentAsPrompt)
        #expect(session.transcript.items.map(\.text) == ["hi"])
        #expect(gateway.params("prompt.submit") == [["session_id": "sid-1", "text": "hi"]])
    }

    @Test func btwQuestionIsAnsweredBesideTheTurn() async throws {
        let gateway = ScriptedGateway()
        gateway.on("prompt.btw", result: ["task_id": "btw_a1b2c3"])
        let session = try await openChat(gateway)
        try await session.send("long task")

        try await session.askBTW("which branch are we on?")
        let row = try #require(session.transcript.items.last)
        #expect(row.role == .system && row.sideQuestion?.isPending == true)
        #expect(gateway.params("prompt.btw") == [["session_id": "sid-1", "text": "which branch are we on?"]])

        // `_spawn_side_agent` emits `{task_id, question, text}` on the parent session (`methods_prompt.py:1063-1082`).
        gateway.transport.sendEvent("btw.complete", payload: ["task_id": "btw_a1b2c3", "text": "main",
                                                               "question": "which branch are we on?"])
        #expect(await eventually { session.transcript.items.last?.sideQuestion?.answer == "main" })
        #expect(session.transcript.isRunning)  // the turn itself is untouched
    }

    /// N4: a client action typed as an alias comes back under its canonical name.
    @Test func aClientActionAliasComesBackCanonical() async throws {
        let gateway = ScriptedGateway()
        gateway.on("commands.catalog", result: [
            "pairs": [["/branch", "Branch this chat"]], "sub": [:], "canon": ["/fork": "/branch"],
            "commands": ["/branch": ["argument_mode": "text", "desktop": nil]],
            "categories": [["name": "Session", "pairs": [["/branch", "Branch this chat"]]]],
            "skills": [:], "skill_count": 0, "warning": "",
        ])
        let session = try await openChat(gateway)
        try await session.loadSlashCommands()

        #expect(try await session.runSlash("/fork at the plan") == .clientAction(name: "branch", argument: "at the plan"))
        #expect(gateway.params("slash.exec").isEmpty)
    }
}
