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
                ForEach(model.knownSources, id: \.self) { source in
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
                Text("Sessions this app starts are stored as Desktop, as Hermes Desktop's are. The list shows only Desktop and Terminal (TUI) sessions, as Hermes Desktop's does; cron runs are under Cron Jobs. Hiding a source only filters the list; nothing is deleted.")
            }
        }
        .navigationTitle("Session Sources")
    }
}
#endif
