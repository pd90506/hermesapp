import HermesKit
import HermesProtocol
import SwiftUI

/// Inline card for a blocking server→client request (approval, clarify,
/// sudo, secret). The agent waits until it is answered or times out.
struct RequestCardView: View {
    let session: ChatSession
    let request: ServerRequest
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let error {
                Text(error).uiFont(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(isClarify ? 1 : 0)) }
    }

    /// A question is no warning: it sits on a plain surface that takes the theme's colour
    /// (a translucent fill), the other requests on orange.
    private var isClarify: Bool {
        if case .clarify = request.kind { true } else { false }
    }

    private var background: AnyShapeStyle {
        isClarify ? AnyShapeStyle(.quinary) : AnyShapeStyle(.orange.opacity(0.12))
    }

    @ViewBuilder
    private var content: some View {
        switch request.kind {
        case .approval(let approval):
            Label("Approval needed", systemImage: "exclamationmark.shield").uiFont(.headline)
            if let description = approval.description { Text(description) }
            if let command = approval.command {
                Text(command)
                    .uiFont(.callout, design: .monospaced)
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
            ClarifyCardView(request: clarify) { answers in
                run { try await session.answer(request, clarify: answers) }
            } skip: {
                run { try await session.answer(request, clarify: nil) }
            }

        case .sudo(let sudo):
            Label("Sudo password requested", systemImage: "lock").uiFont(.headline)
            if let command = sudo.command { Text(command).uiFont(.callout, design: .monospaced) }
            secretEntry

        case .secret(let secret):
            Label(secret.prompt, systemImage: "key").uiFont(.headline)
            Text(secret.envVar).uiFont(.caption, design: .monospaced).foregroundStyle(.secondary)
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
