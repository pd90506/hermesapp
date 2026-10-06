import Foundation
import HermesProtocol
import Testing

/// The `clarify` server request as `server.py:1410-1419` builds it: qids
/// `q0`, `q1`… (`tools/clarify_tool.py:80`), the first choice may carry
/// " (Recommended)", `answers` only on replay.
private let request: JSONValue = [
    "session_id": "sid-1",
    "questions": [
        ["qid": "q0", "question": "Which environments?", "choices": ["staging (Recommended)", "prod", " "],
         "multi_select": true],
        ["qid": "q1", "question": "Deploy now?", "choices": ["yes", "no"], "multi_select": false],
        ["qid": "q2", "question": "Anything else?", "choices": nil, "multi_select": true],
    ],
]

@Suite struct ClarifySelectionTests {
    @Test func multiSelectNeedsChoices() throws {
        let clarify = try request.decode(ClarifyRequest.self)
        #expect(clarify.questions[0].allowsMultipleChoices)
        #expect(clarify.questions[0].offeredChoices == ["staging (Recommended)", "prod"])
        #expect(!clarify.questions[1].allowsMultipleChoices)
        // `multi_select` without choices is an open question (`store/clarify.ts:66-102`).
        #expect(!clarify.questions[2].allowsMultipleChoices)
    }

    /// Desktop's encoding (`clarify/pending.tsx:121-141`), which the tool decodes
    /// as a list (`tools/clarify_tool.py:36-47`).
    @Test func encodesSelectionsLikeDesktop() throws {
        let clarify = try request.decode(ClarifyRequest.self)
        let answers = clarify.answers(for: [
            "q0": ClarifySelection(choices: ["staging (Recommended)", "prod"], other: "dev box"),
            "q1": ClarifySelection(choices: ["no"]),
        ])
        #expect(answers["q0"] == .some(#"["staging","prod","dev box"]"#))
        #expect(answers["q1"] == .some("no"))
        #expect(answers["q2"] == .some(nil))  // skipped

        let wire = try JSONValue(encoding: ClarifyAnswer(answers: answers))
        #expect(wire["answers"]?["q2"] == .null)
    }

    /// Choices over `MAX_CHOICE_CHARS` are dropped (`store/clarify.ts:42-60`);
    /// with none left the question is open-ended, so not a multi-select.
    @Test func overLongChoicesAreDropped() {
        let long = String(repeating: "x", count: ClarifyQuestion.maxChoiceCharacters + 1)
        let question = ClarifyQuestion(qid: "q0", question: "Pick", choices: [long, "ok"], multiSelect: true)
        #expect(question.offeredChoices == ["ok"])
        let open = ClarifyQuestion(qid: "q1", question: "Pick", choices: [long], multiSelect: true)
        #expect(!open.allowsMultipleChoices)
    }

    @Test func readsLockedAnswersBack() throws {
        guard case .object(var raw) = request else { Issue.record("fixture"); return }
        raw["answers"] = ["q0": #"["prod","dev box"]"#, "q1": "yes"]
        let clarify = try JSONValue.object(raw).decode(ClarifyRequest.self)

        #expect(clarify.lockedSelection(for: clarify.questions[0]) == ClarifySelection(choices: ["prod"], other: "dev box"))
        #expect(clarify.lockedSelection(for: clarify.questions[1]) == ClarifySelection(choices: ["yes"]))
        #expect(clarify.lockedSelection(for: clarify.questions[2]) == nil)
    }
}
