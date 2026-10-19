import HermesKit
import SwiftUI

/// The Appearance tab: the same settings as `AppearanceSettingsView` (iOS), as a
/// columns form: light or dark, the theme, the text sizes, and a preview of them all.
struct AppearanceSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model

        Form {
            Picker("Appearance:", selection: $model.appearance.theme) {
                ForEach(AppearanceSettings.Theme.allCases, id: \.self) { theme in
                    Text(AppearanceSettingsView.label(theme)).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("appearanceMode")

            LabeledContent("Theme:") {
                VStack(alignment: .leading, spacing: 6) {
                    ColorThemePicker(selection: model.colorThemeBinding)
                    SettingsNote("Hermes Desktop's themes. They color the window, the sidebar and the chat, the accent colors buttons and marks, and replies take the theme's Markdown colors.")
                }
            }

            Divider()

            sizeRow("UI text:", .ui, note: "The sidebar, lists, tool calls and settings.")
            sizeRow("Content text:", .content, note: "Messages and the composer.")
            sizeRow("Code text:", .code, note: "Code blocks in replies.")

            LabeledContent("Preview:") {
                ThemePreview(scheme: colorScheme)
            }

            LabeledContent {
                Button("Restore Defaults") { model.appearance.reset() }
                    .disabled(model.appearance == AppearanceSettings())
            } label: {
                EmptyView()
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: MacSettingsView.paneWidth)
    }

    /// A size as a number field, "pt" and a stepper, the same width on every row so
    /// the three line up, with what it sizes under it.
    private func sizeRow(_ title: LocalizedStringKey, _ kind: AppearanceSettings.TextKind,
                         note: LocalizedStringKey) -> some View {
        let platformDefault = Double(TextSizes.default(for: kind))
        let size = Binding(
            get: { model.appearance.size(kind, default: platformDefault) },
            set: { model.appearance.setSize(kind, $0, default: platformDefault) })
        return LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField(title, value: size, format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 48)
                        .accessibilityIdentifier("appearanceSizeField.\(kind.rawValue)")
                    Text("pt")
                        .foregroundStyle(.secondary)
                    Stepper(value: size, in: AppearanceSettings.sizeRange, step: 1) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("appearanceSize.\(kind.rawValue)")
                }
                SettingsNote(note)
            }
        }
    }
}
