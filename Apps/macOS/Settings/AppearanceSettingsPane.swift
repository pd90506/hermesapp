import HermesKit
import SwiftUI

/// The Appearance tab: the same settings as `AppearanceSettingsView` (the sheet and
/// iOS), as a columns form.
struct AppearanceSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textSizes) private var sizes

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

            Divider()

            sizeRow("UI text:", .ui)
            sizeRow("Content text:", .content)
            sizeRow("Code text:", .code)
            LabeledContent {
                SettingsNote("UI is the sidebar, lists, tool calls and settings. Content is the messages and the composer. Code is code blocks in replies.")
            } label: {
                EmptyView()
            }

            LabeledContent("Preview:") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The quick brown fox jumps over the lazy dog.")
                        .contentFont()
                    Text("let answer = 42")
                        .font(.system(size: sizes.code, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                }
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
        .frame(width: 560)
    }

    private func sizeRow(_ title: LocalizedStringKey, _ kind: AppearanceSettings.TextKind) -> some View {
        let platformDefault = Double(TextSizes.default(for: kind))
        let size = Binding(
            get: { model.appearance.size(kind, default: platformDefault) },
            set: { model.appearance.setSize(kind, $0, default: platformDefault) })
        return LabeledContent(title) {
            HStack(spacing: 6) {
                Text("\(Int(size.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(model.appearance.isCustom(kind) ? .primary : .secondary)
                    .frame(minWidth: 40, alignment: .trailing)
                Stepper(value: size, in: AppearanceSettings.sizeRange, step: 1) {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityIdentifier("appearanceSize.\(kind.rawValue)")
            }
        }
    }
}
