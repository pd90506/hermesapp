import Foundation
import HermesProtocol

/// System notifications (`GatewayAlert`), raised two ways:
/// - live, from this socket's events and server requests: finished and failed turns,
///   `/background` tasks, credits notices, approvals and questions, as Desktop raises
///   them (`apps/desktop/src/app/session/hooks/use-message-stream/`);
/// - from the session list, when a row's newest reply is one this device hasn't seen or
///   alerted yet (`noteReply`): replies in chats this socket doesn't follow, and, on iOS,
///   replies that came while the app was suspended (`checkForReplies`, run by background
///   app refresh).
///
/// The app's `alertSink` decides (`AlertGate`) and shows them.
extension GatewayConnection {
    /// After a connect, the socket re-delivers what was already there (parked requests,
    /// replayed events): no live alert for that long (`SEED_QUIET_MS`,
    /// `apps/desktop/src/store/notify-baseline.ts`).
    static let alertQuietWindow: TimeInterval = 4

    /// Credits notices worth a system notification (`NATIVE_NOTICE_KEYS`,
    /// `apps/desktop/src/store/agent-notices.ts:32,205`).
    static let alertNoticeKeys: Set<String> = ["credits.depleted", "credits.window_limit", "credits.restored"]

    /// A live reply alerted here is not alerted again when its row is read: the reply is
    /// stored a moment before it arrives here, by the server's clock, which can run
    /// ahead of this device's.
    static let liveReplyMargin: TimeInterval = 120

    // MARK: Live

    func raiseAlert(for event: GatewayEvent) {
        guard alertSink != nil, Date.now >= alertsQuietUntil else { return }
        let sid = event.sessionID ?? ""
        switch event.kind {
        case .messageComplete(let complete):
            switch complete.status {
            case "interrupted":
                return
            case "error":
                let message = complete.error?.trimmed ?? ""
                send(chatAlert(.turnError, title: GatewayAlert.Title.turnError, sid: sid,
                               body: GatewayAlert.body(message, fallback: "The turn failed.")))
            default:
                let alert = chatAlert(.turnDone, title: GatewayAlert.Title.turnDone, sid: sid,
                                      body: GatewayAlert.body(complete.textValue))
                if send(alert), let profile = alert.profile, let stored = alert.storedSessionID {
                    let through = Date.now.addingTimeInterval(Self.liveReplyMargin)
                    updateReplyAlertMarks { $0.markSeen(profile: profile, id: stored, through: through) }
                }
            }
        case .error(let payload):
            send(chatAlert(.turnError, title: GatewayAlert.Title.turnError, sid: sid,
                           body: GatewayAlert.body(payload.message, fallback: "The turn failed.")))
        case .backgroundComplete(let done):
            send(chatAlert(.backgroundDone, title: GatewayAlert.Title.backgroundDone, sid: sid,
                           body: GatewayAlert.body(done.text, fallback: "Done.")))
        case .notificationShow(let notice):
            guard let key = notice.key, Self.alertNoticeKeys.contains(key), !notice.text.trimmed.isEmpty else { return }
            send(GatewayAlert(kind: .credits, title: GatewayAlert.Title.credits, body: notice.text.trimmed))
        default:
            break
        }
    }

    func raiseAlert(for request: ServerRequest) {
        guard alertSink != nil, !request.replayed, Date.now >= alertsQuietUntil else { return }
        let sid = request.sessionID ?? ""
        switch request.kind {
        case .approval(let approval):
            let body = approval.command?.trimmed.nonEmpty ?? approval.description?.trimmed.nonEmpty ?? "A command needs approval."
            var alert = chatAlert(.approval, title: GatewayAlert.Title.approval, sid: sid, body: GatewayAlert.body(body, fallback: body))
            alert.requestID = request.id
            send(alert)
        case .clarify(let clarify):
            let question = clarify.questions.first?.question
            send(chatAlert(.input, title: GatewayAlert.Title.input, sid: sid,
                           body: GatewayAlert.body(question, fallback: GatewayAlert.inputBody)))
        case .sudo, .secret:
            send(chatAlert(.input, title: GatewayAlert.Title.input, sid: sid, body: GatewayAlert.inputBody))
        case .unsupported:
            break
        }
    }

    /// An alert about the chat on runtime session `sid` (the active chat when empty).
    private func chatAlert(_ kind: AlertKind, title: String, sid: String, body: String) -> GatewayAlert {
        let chat: ChatSession?
        if sid.isEmpty || activeSession?.sessionID == sid {
            chat = activeSession
        } else {
            chat = warmChats.first { $0.sessionID == sid }
        }
        let isActive = chat != nil && chat === activeSession
        let profile = chat?.profile ?? sessionProfiles[sid]
        return GatewayAlert(kind: kind, title: title, subtitle: chatLabel(chat, profile: profile, sid: sid), body: body,
                            sessionID: chat?.sessionID ?? (sid.isEmpty ? nil : sid),
                            storedSessionID: chat?.storedSessionID, profile: profile,
                            isBotChat: chat?.kind == .botChat, isActiveChat: isActive,
                            isOnScreen: isActive && isChatOnScreen)
    }

    /// The chat as the session list names it: a Bot Chat by its bot, a side chat by its
    /// title; else the bot, else the id's tail (`withSessionLabel`, `native-notifications.ts:173-183`).
    private func chatLabel(_ chat: ChatSession?, profile: String?, sid: String) -> String? {
        let bot = profile.flatMap { name in bots.first { $0.name == name } }
        if let chat {
            if chat.kind == .botChat, let bot { return bot.displayName }
            if let title = chat.title?.trimmed.nonEmpty { return title }
            if let stored = chat.storedSessionID,
                let row = history.first(where: { $0.profile == chat.profile && $0.summary.id == stored }),
                let name = (row.summary.title ?? row.summary.preview)?.trimmed.nonEmpty {
                return name
            }
        }
        if let bot { return bot.displayName }
        return sid.isEmpty ? nil : "#\(sid.suffix(6))"
    }

    @discardableResult
    private func send(_ alert: GatewayAlert) -> Bool {
        alertSink?(alert) ?? false
    }

    // MARK: From the session list

    /// A row's activity was read: alert its newest reply if this device hasn't seen it
    /// nor alerted it. Either way it counts as alerted from now on, so a reply the user
    /// could see as unread in the list doesn't come back as a notification later.
    func noteReply(profile: String, storedID: String, isBotChat: Bool, label: String?, activity: SessionRowActivity) {
        guard let reply = activity.newestReply,
            replyAlertMarks.isUnread(profile: profile, id: storedID, newestReply: reply)
        else { return }
        updateReplyAlertMarks { $0.markSeen(profile: profile, id: storedID, through: reply) }
        let isActive: Bool
        if let active = activeSession, active.profile == profile {
            isActive = isBotChat ? active.kind == .botChat : active.storedSessionID == storedID
        } else {
            isActive = false
        }
        let isOnScreen = isActive && isChatOnScreen
        guard !isOnScreen, readMarks.isUnread(profile: profile, id: storedID, newestReply: reply) else { return }
        send(GatewayAlert(kind: isActive ? .turnDone : .otherReply,
                          title: isActive ? GatewayAlert.Title.turnDone : GatewayAlert.Title.otherReply,
                          subtitle: label, body: GatewayAlert.body(activity.replyText),
                          sessionID: isActive ? activeSession?.sessionID : nil,
                          storedSessionID: storedID, profile: profile, isBotChat: isBotChat,
                          isActiveChat: isActive, isOnScreen: false))
    }

    /// Reads the session list and every Bot Chat's newest message, and alerts the
    /// replies this device hasn't seen (`noteReply`). For iOS's background app refresh,
    /// when the socket was suspended and missed them; returns once all reads are done.
    public func checkForReplies() async {
        await refreshSessionList()
        await rowActivityTask?.value
        guard let source = messagesSource else { return }
        for bot in bots {
            guard let chat = bot.profile.canonicalSession else { continue }
            var summary = SessionSummary(id: chat.id)
            summary.resolvedID = chat.resolvedID
            let entry = HistoryEntry(profile: bot.name, summary: summary)
            guard let activity = try? await SessionRowActivity.read(for: entry, from: source) else { continue }
            noteReply(profile: bot.name, storedID: chat.id, isBotChat: true, label: bot.displayName, activity: activity)
        }
    }

    func updateReplyAlertMarks(_ change: (inout SessionReadMarks) -> Bool) {
        var marks = replyAlertMarks
        guard change(&marks) else { return }
        replyAlertMarks = marks
        replyAlertMarksChanged?(marks)
    }

    // MARK: Answering from a notification

    /// Approves or rejects the approval request `requestID` (a notification's button),
    /// wherever it waits: in a chat open here, or queued for a chat that isn't.
    public func answerApproval(requestID: String, choice: ApprovalChoice) async throws {
        for chat in [activeSession].compactMap({ $0 }) + warmChats {
            if let request = chat.transcript.pendingRequests.first(where: { $0.id == requestID }) {
                try await chat.answer(request, approval: choice)
                return
            }
        }
        guard let request = otherSessionRequests.first(where: { $0.id == requestID }) else { return }
        guard let client else { throw GatewayClientError.notConnected }
        try await client.answer(request, approval: ApprovalAnswer(choice: choice))
        otherSessionRequests.removeAll { $0.id == requestID }
    }
}
