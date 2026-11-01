import Foundation
import HermesProtocol

/// What the self-improvement review saved after a turn (`review.summary`): Hermes reviews
/// the finished turn in the background and may update memory, the user profile or skills
/// (`summarize_background_review_actions`, `agent/background_review.py:708-740`). The text
/// is "💾 Self-improvement review: Memory updated · Skill 'x' patched"
/// (`display.review.summary_callback`, `locales/en.yaml`). Desktop shows it as a line in
/// the chat, split at the first colon into a label and its detail (`REVIEW_NOTE_RE`,
/// `components/assistant-ui/thread/system-message.tsx:16,89-112`).
public struct ReviewNote: Sendable, Hashable {
    /// "Self-improvement review".
    public var label: String
    /// "Memory updated · Skill 'x' patched"; may be empty.
    public var detail: String

    public init(label: String, detail: String) {
        self.label = label
        self.detail = detail
    }

    /// The summary as sent, without its leading glyph (Desktop strips everything before the
    /// first letter or digit, `gateway-event/status.ts:196-198`); nil when nothing is left.
    static func text(of summary: ReviewSummary) -> String? {
        let text = summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.unicodeScalars.firstIndex(where: {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }) else { return nil }
        return String(text.unicodeScalars[start...])
    }

    /// The label runs to the first colon or line break; the rest is the detail.
    init?(_ text: String) {
        let end = text.firstIndex { $0 == ":" || $0.isNewline } ?? text.endIndex
        let label = text[..<end].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        self.label = label
        var rest = text[end...]
        if rest.first == ":" { rest = rest.dropFirst() }
        detail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension TranscriptItem {
    /// `displayKind` of a system row made from `review.summary`. Shown on this device only,
    /// as in Desktop: never stored, so gone after a reload.
    static let reviewDisplayKind = "review"

    /// A system row the self-improvement review wrote (`ReviewNote`).
    public var reviewNote: ReviewNote? {
        role == .system && displayKind == Self.reviewDisplayKind ? ReviewNote(text) : nil
    }
}
