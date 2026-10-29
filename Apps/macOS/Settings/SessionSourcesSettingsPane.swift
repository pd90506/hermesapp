import HermesKit
import SwiftUI

/// The Session Sources tab: the same settings as `SessionSourcesSettingsView` (iOS), as a
/// columns form.
struct SessionSourcesSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Show in session list:") {
                VStack(alignment: .leading, spacing: 6) {
                    let sources = model.knownSources
                    if sources.isEmpty {
                        Text("Connect and open a profile's sessions to see their sources.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sources, id: \.self) { source in
                        Toggle(isOn: Binding(
                            get: { !model.sourceSettings.isHidden(source) },
                            set: { model.sourceSettings.setHidden(!$0, source) })) {
                            HStack(spacing: 6) {
                                Text(SessionSourceSettings.label(for: source))
                                Text(verbatim: source).foregroundStyle(.secondary)
                            }
                        }
                    }
                    SettingsNote("Sessions this app starts are stored as Desktop, as Hermes Desktop's are. Sessions without a source are always shown. Hiding a source only filters the list; nothing is deleted.")
                        .padding(.top, 2)
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: MacSettingsView.paneWidth)
    }
}
