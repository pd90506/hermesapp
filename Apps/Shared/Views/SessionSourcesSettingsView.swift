#if os(iOS)
import HermesKit
import SwiftUI

/// The session sources: which sources the session list shows
/// (`SessionSourceSettings`). Settings ▸ Session Sources on iOS; the macOS Settings window has `SessionSourcesSettingsPane`.
struct SessionSourcesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ThemedForm {
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
                Text("Sessions this app starts are stored as Desktop, as Hermes Desktop's are. Sessions without a source are always shown. Hiding a source only filters the list; nothing is deleted.")
            }
        }
        .navigationTitle("Session Sources")
    }
}
#endif
