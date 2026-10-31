import Foundation
import HermesKit
import HermesProtocol
import Testing

@Suite struct ClarifyFormTests {
    /// A clarify request's params as Hermes sends them (`tui_gateway/server.py`, `clarify`).
    private func request(_ questions: [[String: Any]], answers: [String: Any]? = nil) throws -> ClarifyRequest {
        var params: [String: Any] = ["session_id": "rt-1", "questions": questions]
        if let answers { params["answers"] = answers }
        return try JSONDecoder().decode(ClarifyRequest.self, from: JSONSerialization.data(withJSONObject: params))
    }

    private var twoQuestions: [[String: Any]] {
        [["qid": "q0", "question": "Colour?", "choices": ["Red (Recommended)", "Green", "Blue"]],
         ["qid": "q1", "question": "Sizes?", "choices": ["S", "M", "L"], "multi_select": true]]
    }

    @Test func aSingleSelectPickMovesOnToTheNextQuestion() throws {
        var form = ClarifyForm(try request(twoQuestions))
        #expect(form.activeIndex == 0)
        #expect(!form.canSend)

        form.pick("Green", in: form.questions[0])

        #expect(form.isPicked("Green", in: form.questions[0]))
        #expect(form.activeIndex == 1)
        #expect(form.answeredCount == 1)
        #expect(form.canSend)
    }

    @Test func aMultiSelectPickTogglesAndKeepsTheOfferedOrder() throws {
        var form = ClarifyForm(try request(twoQuestions))
        form.activeIndex = 1
        let sizes = form.questions[1]

        form.pick("L", in: sizes)
        form.pick("S", in: sizes)
        form.pick("M", in: sizes)
        form.pick("M", in: sizes)

        #expect(form.selection(for: sizes).choices == ["S", "L"])
        #expect(form.activeIndex == 1, "a multi-select pick stays on its question")
        #expect(form.answers["q1"] == #"["S","L"]"#)
        #expect(form.answers["q0"] == .some(nil), "the unanswered question goes as skipped")
    }

    @Test func typedTextReplacesASingleSelectPick() throws {
        var form = ClarifyForm(try request(twoQuestions))
        let colour = form.questions[0]
        form.pick("Red (Recommended)", in: colour)
        #expect(form.answers["q0"] == "Red", "the Recommended label is not sent")

        form.setOther("Teal", for: colour)

        #expect(!form.isPicked("Red (Recommended)", in: colour))
        #expect(form.answers["q0"] == "Teal")
        form.pick("Blue", in: colour)
        #expect(form.selection(for: colour).other.isEmpty)
    }

    @Test func typedTextIsAnExtraValueOnAMultiSelect() throws {
        var form = ClarifyForm(try request(twoQuestions))
        let sizes = form.questions[1]
        form.pick("M", in: sizes)
        form.setOther("XL", for: sizes)
        #expect(form.answers["q1"] == #"["M","XL"]"#)
    }

    @Test func anOpenEndedQuestionIsAnsweredByText() throws {
        var form = ClarifyForm(try request([["qid": "q0", "question": "Why?"]]))
        let question = try #require(form.activeQuestion)
        form.setOther("   ", for: question)
        #expect(!form.canSend, "blank text is no answer")
        form.setOther("Because", for: question)
        #expect(form.answers == ["q0": "Because"])
    }

    @Test func aReplayStartsFromTheLockedAnswersOnTheFirstOpenQuestion() throws {
        let form = ClarifyForm(try request(twoQuestions, answers: ["q0": "Blue"]))
        #expect(form.isPicked("Blue", in: form.questions[0]))
        #expect(form.activeIndex == 1)
    }

    @Test func thePickStaysWhenEveryLaterQuestionIsAnswered() throws {
        var form = ClarifyForm(try request(twoQuestions))
        form.activeIndex = 1
        form.pick("S", in: form.questions[1])
        form.activeIndex = 0
        form.pick("Blue", in: form.questions[0])
        #expect(form.activeIndex == 0, "nothing left to answer: the pick stays in view")
        form.activeIndex = 7
        #expect(form.activeIndex == 1, "clamped to the questions")
    }
}
