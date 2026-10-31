import Foundation
import HermesProtocol
import Testing
@testable import HermesKit

/// Serves each session's newest stored message, by stored id (`GET /api/sessions/{id}/messages`,
/// `hermes_cli/web_routers/sessions.py:739-798`); no timeline.
private actor ReplySource: SessionMessagesSource {
    var newest: [String: StoredMessage] = [:]

    func set(_ id: String, replyAt time: Double, text: String) {
        var row = StoredMessage(id: 1, role: "assistant")
        row.timestamp = time
        row.content = .string(text)
        newest[id] = row
    }

    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        let rows = newest[query.sessionID].map { [$0] } ?? []
        return SessionMessagesPage(messages: rows, pagination:
            SessionMessagesPagination(limit: query.limit, offset: 0, order: "latest", returned: rows.count))
    }

    func timelinePage(_ query: SessionTimelineQuery) async throws -> SessionTimelinePage {
        throw SessionTimelineUnsupported()
    }
}

private func row(_ id: String, count: Int = 2, title: String? = nil) -> HistoryEntry {
    var summary = SessionSummary(id: id, title: title)
    summary.messageCount = count
    return HistoryEntry(profile: "coder", summary: summary)
}

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

/// `session.resume` as Hermes answers it (`session_key`, no `stored_session_id`).
private func server(_ method: String, _ params: JSONValue) -> JSONValue? {
    switch method {
    case "session.resume":
        return ["session_id": "sid-1", "resumed": "stored-1", "session_key": "stored-1", "message_count": 0,
                "messages": [], "info": ["model": "test-model"], "running": false, "status": "idle", "inflight": nil]
    default:
        return .object([:])
    }
}

@MainActor
private final class AlertRecorder {
    var alerts: [GatewayAlert] = []
    var accepts = true
}

@MainActor
private func connection(source: ReplySource? = nil, log: FrameLog = FrameLog(),
                        transport: FakeTransport = FakeTransport()) async throws -> (GatewayConnection, AlertRecorder) {
    transport.serve(log: log, server)
    var configuration = GatewayClient.Configuration()
    configuration.heartbeatInterval = nil
    let connection = GatewayConnection(configuration: configuration)
    try await connection.connect(using: FakeConnector([transport], messages: source))
    connection.alertsQuietUntil = .distantPast
    let recorder = AlertRecorder()
    connection.alertSink = { alert in
        recorder.alerts.append(alert)
        return recorder.accepts
    }
    return (connection, recorder)
}

@MainActor
struct AlertGateTests {
    private func alert(_ kind: AlertKind, active: Bool = false, onScreen: Bool = false,
                       sid: String = "sid-1") -> GatewayAlert {
        GatewayAlert(kind: kind, title: "t", body: "b", sessionID: sid, isActiveChat: active, isOnScreen: onScreen)
    }

    @Test func turnsAlertOnlyForTheActiveChatWhileAway() {
        var prefs = AlertPreferences()
        prefs.showsInApp = false
        let gate = AlertGate(preferences: prefs)
        #expect(!gate.admit(alert(.turnDone, active: true, onScreen: true), appIsActive: true))
        #expect(!gate.admit(alert(.turnDone, active: false), appIsActive: true))
        #expect(!gate.admit(alert(.turnDone, active: false), appIsActive: false))
        #expect(gate.admit(alert(.turnDone, active: true), appIsActive: false))
        #expect(gate.admit(alert(.turnError, active: true), appIsActive: false))
        #expect(gate.admit(alert(.backgroundDone, active: true), appIsActive: false))
    }

    @Test func promptsBreakThroughForAChatNotOnScreen() {
        let gate = AlertGate()
        #expect(!gate.admit(alert(.approval, active: true, onScreen: true), appIsActive: true))
        #expect(gate.admit(alert(.approval, sid: "a"), appIsActive: true))
        #expect(gate.admit(alert(.input, active: true, onScreen: true, sid: "b"), appIsActive: false))
    }

    @Test func creditsAndOtherRepliesWhileAway() {
        var prefs = AlertPreferences()
        prefs.set(.otherReply, on: true)
        prefs.showsInApp = false
        let gate = AlertGate(preferences: prefs)
        #expect(!gate.admit(alert(.credits), appIsActive: true))
        #expect(gate.admit(alert(.credits), appIsActive: false))
        #expect(!gate.admit(alert(.otherReply, sid: "x"), appIsActive: true))
        #expect(gate.admit(alert(.otherReply, sid: "x"), appIsActive: false))
    }

    /// In front, with in-app banners (the default): any chat not on screen.
    @Test func inAppBannersForChatsNotOnScreen() {
        var prefs = AlertPreferences()
        prefs.set(.otherReply, on: true)
        let gate = AlertGate(preferences: prefs)
        #expect(!gate.admit(alert(.turnDone, active: true, onScreen: true), appIsActive: true))
        #expect(gate.admit(alert(.turnDone, active: false, sid: "warm"), appIsActive: true))
        #expect(gate.admit(alert(.turnDone, active: true, sid: "listed"), appIsActive: true))
        #expect(gate.admit(alert(.turnError, sid: "warm"), appIsActive: true))
        #expect(gate.admit(alert(.otherReply, sid: "y"), appIsActive: true))
        #expect(!gate.admit(alert(.credits), appIsActive: true))
    }

    @Test func switchesAndThrottle() {
        let gate = AlertGate()
        // Other replies are off until switched on.
        #expect(!gate.admit(alert(.otherReply), appIsActive: false))
        let now = date(1_000)
        #expect(gate.admit(alert(.approval), appIsActive: false, now: now))
        #expect(!gate.admit(alert(.approval), appIsActive: false, now: now.addingTimeInterval(0.5)))
        #expect(gate.admit(alert(.approval), appIsActive: false, now: now.addingTimeInterval(1.5)))
        gate.preferences.set(.approval, on: false)
        #expect(!gate.admit(alert(.approval, sid: "z"), appIsActive: false))
        gate.preferences.set(.approval, on: true)
        gate.preferences.isEnabled = false
        #expect(!gate.admit(alert(.approval, sid: "z"), appIsActive: false))
    }

    @Test func preferencesDecodeWhatTheyLeaveOut() throws {
        let decoded = try JSONDecoder().decode(AlertPreferences.self, from: Data(#"{"kinds":{"turnDone":false}}"#.utf8))
        #expect(decoded.isEnabled)
        #expect(decoded.showsInApp)
        #expect(!decoded.isOn(.turnDone))
        #expect(decoded.isOn(.approval))
        #expect(!decoded.isOn(.otherReply))
        let empty = try JSONDecoder().decode(AlertPreferences.self, from: Data("{}".utf8))
        #expect(empty == AlertPreferences())
    }

    @Test func bodiesAreCutAndFallBack() {
        #expect(GatewayAlert.body("  ") == "Message complete.")
        #expect(GatewayAlert.body(String(repeating: "x", count: 200)).count == 140)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionAlertTests {
    @Test func liveTurnsAndRequestsRaiseAlerts() async throws {
        let transport = FakeTransport()
        let (connection, recorder) = try await connection(transport: transport)
        let session = try await connection.open(SessionSummary(id: "stored-1", title: "Fix the build"))
        connection.alertsQuietUntil = .distantPast

        transport.sendEvent("message.complete", seq: 1, payload: ["text": "All green.", "status": "complete"])
        #expect(await eventually { recorder.alerts.count == 1 })
        let done = try #require(recorder.alerts.first)
        #expect(done.kind == .turnDone)
        #expect(done.body == "All green.")
        #expect(done.isActiveChat && done.isOnScreen)
        #expect(done.storedSessionID == session.storedSessionID)

        transport.sendEvent("message.complete", seq: 2, payload: ["status": "interrupted"])
        transport.sendEvent("error", seq: 3, payload: ["message": "Out of credits"])
        #expect(await eventually { recorder.alerts.count == 2 })
        #expect(recorder.alerts[1].kind == .turnError)
        #expect(recorder.alerts[1].body == "Out of credits")

        transport.serverSends(["jsonrpc": "2.0", "id": "srq-1", "method": "approval",
                               "params": ["session_id": "elsewhere", "request_id": "ap-1", "command": "rm -rf build"]])
        #expect(await eventually { recorder.alerts.count == 3 })
        let approval = recorder.alerts[2]
        #expect(approval.kind == .approval && approval.body == "rm -rf build" && approval.requestID == "srq-1")
        #expect(!approval.isOnScreen)

        transport.sendEvent("notification.show", sessionID: "", payload: ["text": "Credits restored", "key": "credits.restored"])
        transport.sendEvent("notification.show", sessionID: "", payload: ["text": "50% used", "key": "credits.usage"])
        #expect(await eventually { recorder.alerts.count == 4 })
        #expect(recorder.alerts[3].kind == .credits)
        await connection.disconnect()
    }

    /// Re-deliveries right after a connect, and replayed requests, raise nothing.
    @Test func connectQuietWindowAndReplays() async throws {
        let transport = FakeTransport()
        let (connection, recorder) = try await connection(transport: transport)
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        connection.alertsQuietUntil = .now.addingTimeInterval(60)
        transport.sendEvent("message.complete", seq: 1, payload: ["text": "old", "status": "complete"])
        #expect(await eventually { session.lastSeq == 1 })
        connection.alertsQuietUntil = .distantPast
        connection.raiseAlert(for: ServerRequest(id: "srq-9", method: "sudo", params: ["session_id": "x"], replayed: true))
        transport.sendEvent("message.complete", seq: 2, payload: ["text": "new", "status": "complete"])
        #expect(await eventually { !recorder.alerts.isEmpty })
        #expect(recorder.alerts.map(\.body) == ["new"])
        await connection.disconnect()
    }

    @Test func approvesFromANotification() async throws {
        let transport = FakeTransport()
        let log = FrameLog()
        let (connection, _) = try await connection(log: log, transport: transport)
        _ = try await connection.open(SessionSummary(id: "stored-1"))
        transport.serverSends(["jsonrpc": "2.0", "id": "srq-2", "method": "approval",
                               "params": ["session_id": "elsewhere", "request_id": "ap-2", "command": "ls"]])
        #expect(await eventually { connection.otherSessionRequests.map(\.id) == ["srq-2"] })
        try await connection.answerApproval(requestID: "srq-2", choice: .deny)
        #expect(connection.otherSessionRequests.isEmpty)
        #expect(await eventually {
            log.all.contains { $0["id"]?.stringValue == "srq-2" && $0["result"]?["choice"]?.stringValue == "deny" }
        })
        await connection.disconnect()
    }

    /// Replies read from the session list: each new one once, none from before alerts
    /// started, and none the user already saw.
    @Test func listRepliesAlertOnce() async throws {
        let source = ReplySource()
        await source.set("a", replyAt: 2_000, text: "Report ready")
        await source.set("b", replyAt: 500, text: "old news")
        let (connection, recorder) = try await connection(source: source)
        var marks = SessionReadMarks()
        marks.start(now: date(1_000))
        connection.readMarks = marks
        connection.replyAlertMarks = marks

        await connection.readRowActivity([row("a", title: "Weekly report"), row("b")])
        #expect(recorder.alerts.count == 1)
        let reply = try #require(recorder.alerts.first)
        #expect(reply.kind == .otherReply && reply.subtitle == "Weekly report" && reply.body == "Report ready")
        #expect(reply.storedSessionID == "a" && reply.profile == "coder")

        // Read again with a newer count but the same reply: nothing new.
        await connection.readRowActivity([row("a", count: 3), row("b")])
        #expect(recorder.alerts.count == 1)

        // A newer reply the user already saw: counted, not alerted.
        await source.set("a", replyAt: 3_000, text: "Seen")
        connection.readMarks.markSeen(profile: "coder", id: "a", through: date(3_000))
        await connection.readRowActivity([row("a", count: 4)])
        #expect(recorder.alerts.count == 1)
        #expect(!connection.replyAlertMarks.isUnread(profile: "coder", id: "a", newestReply: date(3_000)))
        await connection.disconnect()
    }

    /// A reply alerted live is not alerted again when its row is read.
    @Test func liveReplyIsNotAlertedTwice() async throws {
        let transport = FakeTransport()
        let source = ReplySource()
        let (connection, recorder) = try await connection(source: source, transport: transport)
        var marks = SessionReadMarks()
        marks.start(now: date(1_000))
        connection.readMarks = marks
        connection.replyAlertMarks = marks
        let session = try await connection.open(row("stored-1"))
        connection.alertsQuietUntil = .distantPast
        connection.isChatOnScreen = false
        transport.sendEvent("message.complete", seq: 1, payload: ["text": "Done", "status": "complete"])
        #expect(await eventually { recorder.alerts.count == 1 })
        #expect(session.storedSessionID == "stored-1")

        await source.set("stored-1", replyAt: Date.now.timeIntervalSince1970, text: "Done")
        await connection.readRowActivity([row("stored-1", count: 3)])
        #expect(recorder.alerts.count == 1)
        await connection.disconnect()
    }
}
