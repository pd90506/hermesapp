import HermesKit
import SwiftUI

/// Light, dark or the system's look, the theme (`ColorTheme`), and the UI, content and
/// code text sizes (`AppearanceSettings`, kept by `AppModel`). Settings ▸ Appearance on
/// iOS; the macOS Settings window has `AppearanceSettingsPane`.
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model

        ThemedForm {
            Section("Mode") {
                Picker("Mode", selection: $model.appearance.theme) {
                    ForEach(AppearanceSettings.Theme.allCases, id: \.self) { theme in
                        Text(Self.label(theme)).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("appearanceMode")
            }

            Section {
                ColorThemePicker(selection: model.colorThemeBinding)
                    .frame(maxWidth: .infinity)
            } header: {
                Text("Theme")
            } footer: {
                Text("Hermes Desktop's themes, with Codex and Claude Code. The accent colors buttons, your messages and selections; replies take the theme's Markdown colors.")
            }

            Section {
                sizeRow("UI", .ui)
                sizeRow("Content", .content)
                sizeRow("Code", .code)
            } header: {
                Text("Text Size")
            } footer: {
                Text("UI is the sidebar, lists, tool calls and settings. Content is the messages and the composer. Code is code blocks in replies.")
            }

            Section("Preview") {
                ThemePreview(scheme: colorScheme)
            }

            // Markdown Colors (`MarkdownColorsSettingsView`, a colour per element) is hidden
            // for now (user, 2026-10): the theme sets the Markdown colours.

            Section {
                Button("Restore Defaults") { model.appearance.reset() }
                    .disabled(model.appearance == AppearanceSettings())
            }
        }
        .navigationTitle("Appearance")
    }

    private func sizeRow(_ title: String, _ kind: AppearanceSettings.TextKind) -> some View {
        let platformDefault = Double(TextSizes.default(for: kind))
        let size = Binding(
            get: { model.appearance.size(kind, default: platformDefault) },
            set: { model.appearance.setSize(kind, $0, default: platformDefault) })
        return Stepper(value: size, in: AppearanceSettings.sizeRange, step: 1) {
            LabeledContent(title) {
                Text("\(Int(size.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(model.appearance.isCustom(kind) ? .primary : .secondary)
            }
        }
        .accessibilityIdentifier("appearanceSize.\(kind.rawValue)")
    }

    static func label(_ theme: AppearanceSettings.Theme) -> String {
        switch theme {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
