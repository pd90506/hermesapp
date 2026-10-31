import HermesProtocol

/// What the clarify card has staged for one request: a selection per question and the
/// question on show. Nothing reaches the server until the card sends every answer at
/// once, as Desktop's batch card does (`components/assistant-ui/clarify/pending.tsx`).
///
/// One question shows at a time, as Claude Code's question card does: picking a choice
/// of a single-select question moves on to the next unanswered one.
public struct ClarifyForm: Sendable, Hashable {
    public let request: ClarifyRequest
    public private(set) var selections: [String: ClarifySelection]
    /// The index in `questions` of the question on show.
    public var activeIndex: Int {
        didSet { activeIndex = min(max(activeIndex, 0), max(questions.count - 1, 0)) }
    }

    /// Starts from the answers already locked (a replayed request), on the first
    /// question without one.
    public init(_ request: ClarifyRequest) {
        self.request = request
        var selections: [String: ClarifySelection] = [:]
        for question in request.questions {
            if let locked = request.lockedSelection(for: question) { selections[question.qid] = locked }
        }
        self.selections = selections
        activeIndex = 0
        activeIndex = questions.firstIndex { !isAnswered($0) } ?? 0
    }

    public var questions: [ClarifyQuestion] { request.questions }

    public var activeQuestion: ClarifyQuestion? {
        questions.indices.contains(activeIndex) ? questions[activeIndex] : nil
    }

    public func selection(for question: ClarifyQuestion) -> ClarifySelection {
        selections[question.qid] ?? ClarifySelection()
    }

    public func isPicked(_ choice: String, in question: ClarifyQuestion) -> Bool {
        selection(for: question).choices.contains(choice)
    }

    /// Whether the question would be sent with an answer rather than as skipped.
    public func isAnswered(_ question: ClarifyQuestion) -> Bool {
        question.answer(for: selection(for: question)) != nil
    }

    public var answeredCount: Int { questions.filter(isAnswered).count }

    /// Sending needs one answer at least; the rest go as skipped (Desktop's `canConfirm`).
    public var canSend: Bool { answeredCount > 0 }

    /// The `{qid: answer}` map to send.
    public var answers: [String: String?] { request.answers(for: selections) }

    /// Picks a choice. A single-select question takes it in place of anything picked or
    /// typed before, and the card moves on to the next unanswered question; a
    /// multi-select one toggles it and keeps the typed text.
    public mutating func pick(_ choice: String, in question: ClarifyQuestion) {
        var selection = selection(for: question)
        if question.allowsMultipleChoices {
            if let index = selection.choices.firstIndex(of: choice) {
                selection.choices.remove(at: index)
            } else {
                // Kept in the order offered, whatever order they were picked in.
                selection.choices = question.offeredChoices.filter { selection.choices.contains($0) || $0 == choice }
            }
            selections[question.qid] = selection
        } else {
            selections[question.qid] = ClarifySelection(choices: [choice])
            advance(from: question)
        }
    }

    /// The typed ("Other") answer. On a single-select question typed text replaces the
    /// picked choice; on a multi-select one it is an extra value.
    public mutating func setOther(_ text: String, for question: ClarifyQuestion) {
        var selection = selection(for: question)
        selection.other = text
        if !question.allowsMultipleChoices, !text.isEmpty { selection.choices = [] }
        selections[question.qid] = selection
    }

    /// Whether there is a question after the one on show.
    public var hasNext: Bool { activeIndex < questions.count - 1 }

    /// Shows the next unanswered question after `question`; stays put when every later one is answered.
    private mutating func advance(from question: ClarifyQuestion) {
        guard let index = questions.firstIndex(where: { $0.qid == question.qid }) else { return }
        let later = questions.indices.dropFirst(index + 1)
        if let next = later.first(where: { !isAnswered(questions[$0]) }) { activeIndex = next }
    }
}
