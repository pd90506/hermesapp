import HermesKit
import HermesProtocol
import SwiftUI

/// The clarify card: Hermes's questions with their choices laid out as rows to tap, as
/// Claude Code's question card and Desktop's batch card show them, rather than folded
/// into a menu (the user, 2026-10-31). One question shows at a time, with a strip to
/// switch between them; the answers go out together (`ClarifyForm`).
struct ClarifyCardView: View {
    let request: ClarifyRequest
    let send: ([String: String?]) -> Void
    let skip: () -> Void
    @State private var form: ClarifyForm

    init(request: ClarifyRequest, send: @escaping ([String: String?]) -> Void, skip: @escaping () -> Void) {
        self.request = request
        self.send = send
        self.skip = skip
        _form = State(initialValue: ClarifyForm(request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if form.questions.count > 1 { questionStrip }
            if let question = form.activeQuestion {
                ClarifyQuestionView(question: question, form: $form)
                    .id(question.qid)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(form.questions.count > 1 ? "Hermes has \(form.questions.count) questions" : "Hermes has a question",
                  systemImage: "questionmark.bubble")
                .uiFont(.headline)
            Spacer(minLength: 8)
            if form.questions.count > 1 {
                Text("\(form.answeredCount) of \(form.questions.count) answered")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clarifyProgress")
            }
        }
    }

    /// One segment per question, ticked once it has an answer.
    private var questionStrip: some View {
        Picker("Question", selection: $form.activeIndex) {
            ForEach(Array(form.questions.enumerated()), id: \.element.qid) { index, question in
                Text(form.isAnswered(question) ? "\(index + 1) ✓" : "\(index + 1)").tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("clarifyQuestions")
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Skip", action: skip)
                .accessibilityIdentifier("clarifySkip")
            if form.hasNext {
                Button("Next") { form.activeIndex += 1 }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("clarifyNext")
            }
            Button("Send Answers") { send(form.answers) }
                .buttonStyle(.borderedProminent)
                .disabled(!form.canSend)
                .accessibilityIdentifier("clarifySend")
        }
        .controlSize(.regular)
    }
}

/// One question: its text, then a numbered row per choice and a row to type an answer.
private struct ClarifyQuestionView: View {
    let question: ClarifyQuestion
    @Binding var form: ClarifyForm
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.question)
                    .uiFont(.body, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !question.offeredChoices.isEmpty {
                    Text(question.allowsMultipleChoices ? "Select all that apply" : "Pick one")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(question.offeredChoices.enumerated()), id: \.offset) { index, choice in
                ClarifyChoiceRow(number: index + 1, choice: choice,
                                 isPicked: form.isPicked(choice, in: question),
                                 isMultiple: question.allowsMultipleChoices) {
                    typing = false
                    form.pick(choice, in: question)
                }
            }
            otherRow
        }
    }

    /// "Other" under the choices, or the answer field of an open-ended question.
    private var otherRow: some View {
        let text = form.selection(for: question).other
        let hasChoices = !question.offeredChoices.isEmpty
        return HStack(spacing: 10) {
            if hasChoices {
                ClarifyNumberBadge(number: question.offeredChoices.count + 1,
                                   isPicked: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField(hasChoices ? "Other (type your answer)" : "Type your answer…",
                      text: Binding(get: { text }, set: { form.setOther($0, for: question) }), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($typing)
                .accessibilityIdentifier("clarifyOther")
        }
        .clarifyRow(isPicked: typing || !text.isEmpty)
        .contentShape(.rect)
        .onTapGesture { typing = true }
    }
}

private struct ClarifyChoiceRow: View {
    let number: Int
    let choice: String
    let isPicked: Bool
    let isMultiple: Bool
    let action: () -> Void

    var body: some View {
        let label = ClarifyQuestion.bareChoice(choice)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ClarifyNumberBadge(number: number, isPicked: isPicked)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if label != choice {
                        Text("Recommended").uiFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isMultiple {
                    Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                } else if isPicked {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
            .clarifyRow(isPicked: isPicked)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("clarifyChoice")
    }
}

/// The row's number, as Claude Code numbers its options; filled once picked.
private struct ClarifyNumberBadge: View {
    let number: Int
    let isPicked: Bool

    var body: some View {
        Text("\(number)")
            .uiFont(.caption, weight: .semibold, design: .rounded)
            .monospacedDigit()
            .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 20, height: 20)
            .background(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
            .accessibilityHidden(true)
    }
}

private extension View {
    func clarifyRow(isPicked: Bool) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quinary),
                        in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isPicked ? AnyShapeStyle(.tint.opacity(0.7)) : AnyShapeStyle(.clear), lineWidth: 1)
            }
    }
}
