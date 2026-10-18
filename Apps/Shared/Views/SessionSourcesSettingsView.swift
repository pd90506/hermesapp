#if os(iOS)
import HermesKit
import SwiftUI

/// The session sources: which source sessions this app creates carry, and which
/// sources the session list shows (`SessionSourceSettings`). Settings ▸ Session
/// Sources on iOS; the macOS Settings window has `SessionSourcesSettingsPane`.
struct SessionSourcesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Source", selection: $model.sourceSettings.newSessionSource) {
                    Text("Server default").tag(String?.none)
                    ForEach(SessionSourceSettings.creatableSources, id: \.self) { source in
                        Text(SessionSourceSettings.label(for: source)).tag(Optional(source))
                    }
                }
            } header: {
                Text("New Sessions")
            } footer: {
                Text("The source Hermes stores on sessions this app starts. By default the server picks: Desktop under Hermes Desktop's backend, Terminal (TUI) under any other, the one this app runs included.")
            }

            Section {
                let sources = model.knownSources
                if sources.isEmpty {
                    Text("Connect and open a profile's sessions to see their sources.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sources, id: \.self) { source in
                    Toggle(isOn: Binding(
                        get: { !model.sourceSettings.isHidden(source) },
                        set: { model.sourceSettings.setHidden(!$0, source) })) {
                        Text(SessionSourceSettings.label(for: source))
                        Text(source)
                    }
                }
            } header: {
                Text("Shown in the Session List")
            } footer: {
                Text("Sessions without a source are always shown. Hiding a source only filters the list; nothing is deleted.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Session Sources")
    }
}
#endif
