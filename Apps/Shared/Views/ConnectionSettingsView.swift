import HermesKit
import SwiftUI

/// Server URL + credentials. Shown as a sheet on first launch and from the
/// toolbar; also the macOS Settings window.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                TextField("Server URL", text: $model.settings.serverURL,
                          prompt: Text("https://hermes.example.ts.net"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Check Server") {
                    Task { await model.probe() }
                }
                .disabled(model.settings.serverURL.isEmpty)
                if let probe = model.probeResult {
                    Text(probe).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Hermes Dashboard")
            } footer: {
                Text("The address of the Hermes dashboard (the same one the desktop app uses), e.g. a Tailscale HTTPS name.")
            }

            Section("Sign-in") {
                Picker("Method", selection: $model.settings.authMode) {
                    ForEach(AuthMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if model.settings.authMode == .password {
                    TextField("Provider", text: $model.settings.provider)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Username", text: $model.settings.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                SecureField(model.settings.authMode.secretLabel, text: $model.secret)
                    .textContentType(.password)
                if let help = model.settings.authMode.help {
                    Text(help).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let error = model.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        isWorking = true
                        await model.connect()
                        isWorking = false
                        if model.isConnected { dismiss() }
                    }
                } label: {
                    HStack {
                        Text(model.isConnected ? "Reconnect" : "Connect")
                        if isWorking {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.settings.serverURL.isEmpty || isWorking)

                if model.isConnected {
                    Button("Disconnect", role: .destructive) {
                        Task { await model.disconnect() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            #endif
        }
    }
}
