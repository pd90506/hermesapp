import AuthenticationServices
import HermesKit
import SwiftUI

/// The browser sign-in (`AuthMode.browser`) in a server's settings: whether the server is
/// signed in, and Sign In, which opens the dashboard's own sign-in page
/// (`AppModel.signInWithBrowser`). On the Mac that is the default browser, as Hermes
/// Desktop signs in; on iOS the system's sign-in sheet, which keeps the app (and its
/// loopback listener) in the foreground.
struct BrowserSignInButton: View {
    let server: ServerConnection
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    #endif
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if task == nil {
                Button(isSignedIn ? "Sign In Again…" : "Sign In with Browser…", action: signIn)
                    .disabled(!server.hasURL)
                    .accessibilityIdentifier("browserSignIn")
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { task?.cancel() }
            }
            if task == nil {
                Label(isSignedIn ? "Signed in" : "Not signed in",
                      systemImage: isSignedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(isSignedIn ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .uiFont(.callout)
            }
        }
    }

    private var isSignedIn: Bool {
        server.config.authMode == .browser && NativeTokens(secret: server.secret) != nil
    }

    private func signIn() {
        task = Task {
            await model.signInWithBrowser(server, open: open)
            task = nil
        }
    }

    /// Shows the sign-in page; returns when it can no longer call back (the sheet closed).
    private func open(_ url: URL) async throws {
        #if os(iOS)
        do {
            // The redirect goes to the listener, not to this scheme, so this only ends when
            // the sheet is closed or the sign-in task is cancelled once the listener has it.
            _ = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "talaria",
                                                                preferredBrowserSession: .ephemeral)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw CancellationError()
        }
        #else
        openURL(url)
        // The browser is the user's: wait for the callback, Cancel, or 10 minutes.
        try await Task.sleep(for: .seconds(600))
        #endif
    }
}
