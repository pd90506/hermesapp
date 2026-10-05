import HermesKit
import HermesProtocol
import SwiftUI

/// Inline card for a blocking server→client request (approval, clarify,
/// sudo, secret). The agent waits until it is answered or times out.
struct RequestCardView: View {
    let session: ChatSession
    let request: ServerRequest
    @State private var text = ""
    @State private var clarifyAnswers: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var content: some View {
        switch request.kind {
        case .approval(let approval):
            Label("Approval needed", systemImage: "exclamationmark.shield").font(.headline)
            if let description = approval.description { Text(description) }
            if let command = approval.command {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            }
            HStack {
                ForEach(approval.offeredChoices, id: \.self) { choice in
                    Button(title(for: choice), role: choice == .deny ? .destructive : nil) {
                        run { try await session.answer(request, approval: choice) }
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .clarify(let clarify):
            Label("Hermes has a question", systemImage: "questionmark.bubble").font(.headline)
            ForEach(clarify.questions) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question)
                    if let choices = question.choices, !choices.isEmpty {
                        Picker(question.question, selection: binding(for: question.qid)) {
                            Text("Choose…").tag("")
                            ForEach(choices, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    } else {
                        TextField("Answer", text: binding(for: question.qid))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Button("Send Answers") {
                    // `uniquingKeysWith`: a duplicate qid from the server must not trap.
                    let answers = Dictionary(clarify.questions.map { question -> (String, String?) in
                        let value = clarifyAnswers[question.qid] ?? ""
                        return (question.qid, value.isEmpty ? nil : value)
                    }, uniquingKeysWith: { first, _ in first })
                    run { try await session.answer(request, clarify: answers) }
                }
                .buttonStyle(.borderedProminent)
                Button("Skip") { run { try await session.answer(request, clarify: nil) } }
            }

        case .sudo(let sudo):
            Label("Sudo password requested", systemImage: "lock").font(.headline)
            if let command = sudo.command { Text(command).font(.callout.monospaced()) }
            secretEntry

        case .secret(let secret):
            Label(secret.prompt, systemImage: "key").font(.headline)
            Text(secret.envVar).font(.caption.monospaced()).foregroundStyle(.secondary)
            secretEntry

        case .unsupported:
            Label("Unsupported request: \(request.method)", systemImage: "questionmark.diamond")
            Button("Dismiss") { run { try await session.answer(request, value: "") } }
        }
    }

    private var secretEntry: some View {
        HStack {
            SecureField("Value", text: $text)
                .textFieldStyle(.roundedBorder)
            Button("Send") { run { try await session.answer(request, value: text) } }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty)
            Button("Skip") { run { try await session.answer(request, value: "") } }
        }
    }

    private func binding(for qid: String) -> Binding<String> {
        Binding(get: { clarifyAnswers[qid] ?? "" }, set: { clarifyAnswers[qid] = $0 })
    }

    private func title(for choice: ApprovalChoice) -> String {
        switch choice {
        case .once: "Allow Once"
        case .session: "Allow for Session"
        case .always: "Always Allow"
        case .deny: "Deny"
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do { try await action() } catch { self.error = GatewayConnection.describe(error) }
        }
    }
}
