import Foundation

/// A message Hermes writes into the chat as a user turn when background work ends: a
/// background process finished, matched a watch pattern or sent a heartbeat, or an
/// async subagent finished (`format_process_notification`,
/// `tools/process_registry_notifications.py:428-471`). Not something the user typed, so
/// the chat shows it as a compact line, as Desktop does (`ProcessNotificationNote`,
/// `apps/desktop/src/components/assistant-ui/thread/user-message.tsx:237-244,411-421`).
public struct BackgroundNotice: Sendable, Hashable {
    /// The first line, without the `[IMPORTANT: …]` wrapper.
    public var headline: String
    /// The rest: command, output, result.
    public var detail: String

    /// Hermes's own test for these prompts (`_SYNTHETIC_PROMPT`,
    /// `hermes_state_timeline.py:13-17`), plus the heartbeat rows Desktop also leaves
    /// out of the conversation (`LEGACY_HEARTBEAT_ROW_RE`, `lib/chat-messages/hydration.ts:33`).
    static let pattern = #"^\s*(?:\[IMPORTANT: Background process |\[ASYNC (?:DELEGATION )?(?:BATCH )?COMPLETE\b|A background fan-out of \d+ subagent\(s\) you dispatched earlier has finished\.|A background subagent you dispatched earlier has finished\.|\[Background process \S+ heartbeat #\d+ )"#

    public init?(_ text: String) {
        guard text.range(of: Self.pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("[IMPORTANT:") {
            body = String(body.dropFirst("[IMPORTANT:".count))
            if body.hasSuffix("]") { body.removeLast() }
        } else if body.hasPrefix("[Background process"), body.hasSuffix("]") {
            body = String(body.dropFirst().dropLast())
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        headline = String(lines.first ?? "").trimmingCharacters(in: .whitespaces)
        detail = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}

extension TranscriptItem {
    /// A user row Hermes wrote for finished background work (`BackgroundNotice`).
    public var backgroundNotice: BackgroundNotice? {
        role == .user ? BackgroundNotice(text) : nil
    }
}
