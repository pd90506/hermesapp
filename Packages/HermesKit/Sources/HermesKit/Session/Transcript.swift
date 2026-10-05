import Foundation
import HermesProtocol

/// One row of the chat as the UI shows it.
public struct TranscriptItem: Sendable, Hashable, Identifiable {
    public enum Role: Sendable, Hashable {
        case user, assistant, tool, system
    }

    public var id: String
    public var role: Role
    public var text: String
    /// Assistant reasoning/thinking streamed alongside the reply.
    public var reasoning: String = ""
    /// Tool rows: the tool name.
    public var toolName: String?
    /// Tool rows: short context at start (command/path), summary when done.
    public var detail: String?
    /// Assistant: still receiving deltas. Tool: still running.
    public var isActive: Bool = false
    /// Assistant: `message.complete` status (`complete` | `error` | `interrupted`).
    public var outcome: String?

    public init(id: String, role: Role, text: String, isActive: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isActive = isActive
    }
}

/// Pure reducer from gateway snapshots and events to a display transcript.
///
/// Kept free of I/O so it is fully unit-tested on Linux. Event semantics
/// follow `tui_gateway/contracts/events.py`; see `docs/protocol.md`.
public struct Transcript: Sendable, Hashable {
    public private(set) var items: [TranscriptItem] = []
    /// A turn is running (between submit/`message.start` and `message.complete`).
    public private(set) var isRunning = false
    /// Latest `status.update` text while running.
    public private(set) var status: String?
    /// Last session-level or turn error.
    public private(set) var lastError: String?
    /// Unanswered server→client requests for this session, oldest first.
    public private(set) var pendingRequests: [ServerRequest] = []

    private var counter = 0

    public init() {}

    /// Rebuilds from `session.resume` / `session.activate` / `session.create`.
    public init(snapshot: LiveSessionSnapshot) {
        for message in snapshot.messages {
            switch message.role {
            case "user": append(.user, message.plainText)
            case "assistant":
                let text = message.plainText
                if text.isEmpty && message.reasoning == nil { continue }
                append(.assistant, text)
                items[items.count - 1].reasoning = message.reasoning ?? ""
            case "tool":
                // Same id scheme as `tool.start` rows so a resumed running tool is not duplicated.
                var item = TranscriptItem(id: message.toolCallID.map(Self.toolItemID) ?? nextID(), role: .tool, text: "")
                item.toolName = message.name
                item.detail = message.context
                items.append(item)
            case "system": append(.system, message.plainText)
            default: continue
            }
        }
        // The turn that was in flight when we attached: what streamed so far,
        // or a retained *failed* turn (`inflight.error`, `streaming:false`),
        // which is over and must not spin.
        if let inflight = snapshot.inflight {
            if let user = inflight.user, !user.isEmpty, items.last?.role != .user || items.last?.text != user {
                append(.user, user)
            }
            let assistant = inflight.assistant ?? ""
            if inflight.isFailed {
                if !assistant.isEmpty {
                    let index = append(.assistant, assistant)
                    items[index].outcome = inflight.status ?? "error"
                }
                lastError = inflight.error
                isRunning = snapshot.running == true
            } else {
                let streaming = inflight.streaming ?? (snapshot.running == true)
                append(.assistant, assistant, active: streaming)
                isRunning = streaming || snapshot.running == true
            }
        } else if snapshot.running == true {
            isRunning = true
        }
    }

    static func toolItemID(_ toolID: String) -> String { "tool-" + toolID }

    // MARK: - Local actions

    /// Optimistically shows the user's prompt; call before `prompt.submit`.
    public mutating func appendUserPrompt(_ text: String) {
        append(.user, text)
        isRunning = true
        lastError = nil
    }

    /// Marks a failed submit so the UI does not spin forever.
    public mutating func submitFailed(_ message: String) {
        isRunning = false
        lastError = message
    }

    public mutating func addRequest(_ request: ServerRequest) {
        guard !pendingRequests.contains(where: { $0.id == request.id }) else { return }
        pendingRequests.append(request)
    }

    public mutating func removeRequest(id: String) {
        pendingRequests.removeAll { $0.id == id }
    }

    // MARK: - Events

    public mutating func apply(_ event: GatewayEvent) {
        switch event.kind {
        case .messageStart:
            isRunning = true
            if activeAssistantIndex == nil { append(.assistant, "", active: true) }

        case .messageDelta(let delta):
            isRunning = true
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            items[index].text += delta.text

        case .reasoningDelta(let delta):
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            items[index].reasoning += delta.text

        case .reasoningAvailable(let delta):
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            if items[index].reasoning.isEmpty { items[index].reasoning = delta.text }

        case .messageInterim(let interim):
            // Commentary beside tool calls is sealed as its own segment.
            if interim.alreadyStreamed == true, let index = activeAssistantIndex {
                items[index].isActive = false
            } else if !interim.text.isEmpty {
                sealActiveAssistant()
                append(.assistant, interim.text)
            }

        case .toolGenerating:
            sealActiveAssistant()

        case .toolStart(let start):
            sealActiveAssistant()
            let id = Self.toolItemID(start.toolID)
            if let index = items.lastIndex(where: { $0.id == id }) {
                items[index].isActive = true  // already shown by the resume snapshot
            } else {
                var item = TranscriptItem(id: id, role: .tool, text: "", isActive: true)
                item.toolName = start.name
                item.detail = start.context ?? start.preview
                items.append(item)
            }

        case .toolComplete(let complete):
            if let index = items.lastIndex(where: { $0.id == Self.toolItemID(complete.toolID) }) {
                items[index].isActive = false
                if let summary = complete.summary, !summary.isEmpty { items[index].detail = summary }
            } else {
                var item = TranscriptItem(id: Self.toolItemID(complete.toolID), role: .tool, text: "")
                item.toolName = complete.name
                item.detail = complete.summary
                items.append(item)
            }

        case .messageComplete(let complete):
            finishTurn(complete)

        case .statusUpdate(let update):
            status = update.text.isEmpty ? nil : update.text

        case .error(let payload):
            lastError = payload.message

        case .requestCancel(let cancel):
            removeRequest(id: cancel.id)

        case .approvalCancelled(let cancelled):
            // `request_ids` are approval request ids (params.request_id), not frame ids.
            let ids = Set(cancelled.requestIDs)
            pendingRequests.removeAll { request in
                if case .approval(let approval) = request.kind { return ids.contains(approval.requestID) }
                return false
            }

        case .gatewayReady, .sessionTitle, .sessionInfo, .unknown:
            break
        }
    }

    // MARK: - Helpers

    private var activeAssistantIndex: Int? {
        guard let last = items.indices.last, items[last].role == .assistant, items[last].isActive else { return nil }
        return last
    }

    private mutating func sealActiveAssistant() {
        guard let index = activeAssistantIndex else { return }
        items[index].isActive = false
        if items[index].text.isEmpty && items[index].reasoning.isEmpty { items.remove(at: index) }
    }

    private mutating func finishTurn(_ complete: MessageComplete) {
        let finalText = complete.textValue
        if let index = activeAssistantIndex {
            if items[index].text.isEmpty { items[index].text = finalText }
            if items[index].reasoning.isEmpty, let reasoning = complete.reasoning { items[index].reasoning = reasoning }
            items[index].isActive = false
            items[index].outcome = complete.status
        } else if !finalText.isEmpty, !lastAssistantSinceUser(contains: finalText) {
            let index = append(.assistant, finalText)
            items[index].outcome = complete.status
        } else if let index = items.indices.last, items[index].role == .assistant {
            items[index].outcome = complete.status
        }
        for index in items.indices where items[index].role == .tool { items[index].isActive = false }
        if complete.status == "error" { lastError = complete.error ?? "The turn failed." }
        isRunning = false
        status = nil
    }

    /// Avoids duplicating a reply that already streamed into a sealed segment.
    private func lastAssistantSinceUser(contains text: String) -> Bool {
        for item in items.reversed() {
            if item.role == .user { return false }
            if item.role == .assistant, item.text == text { return true }
        }
        return false
    }

    private mutating func nextID() -> String {
        counter += 1
        return "local-\(counter)"
    }

    @discardableResult
    private mutating func append(_ role: TranscriptItem.Role, _ text: String, active: Bool = false) -> Int {
        items.append(TranscriptItem(id: nextID(), role: role, text: text, isActive: active))
        return items.count - 1
    }
}
