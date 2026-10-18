import HermesKit
import SwiftUI

/// The Markdown tab: the theme's colours (Appearance), a light and a dark colour for each
/// element, and a live
/// preview of a reply in either look. The same settings as `MarkdownColorsSettingsView`
/// (iOS).
struct MarkdownSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    /// The look the preview shows; nil follows the app's.
    @State private var previewScheme: ColorScheme?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Theme:") {
                        Text(ColorThemePicker.label(model.markdownColors.preset))
                    }
                    .fixedSize()
                    .accessibilityIdentifier("markdownTheme")
                    SettingsNote("The colors start from the app's theme, set in Appearance.")
                }

                // Thirteen rows outgrow a short screen: they scroll, the pane keeps its height.
                ScrollView {
                    colorGrid
                        .padding(.trailing, 12)
                }
                .scrollIndicators(.automatic)

                Button("Restore Theme Colors") { model.markdownColors.resetColors() }
                    .disabled(!model.markdownColors.hasCustomColors)
            }
            .frame(width: 330, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Preview", selection: previewSchemeBinding) {
                    Text("Light").tag(ColorScheme.light)
                    Text("Dark").tag(ColorScheme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("markdownPreviewScheme")
                MarkdownColorsPreview(scheme: previewSchemeBinding.wrappedValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: MacSettingsView.paneWidth, height: Self.paneHeight)
    }

    /// Room for the preview and most of the colors; fits a 768 pt screen with the Dock.
    static let paneHeight: CGFloat = 560

    private var previewSchemeBinding: Binding<ColorScheme> {
        Binding(get: { previewScheme ?? colorScheme }, set: { previewScheme = $0 })
    }

    /// One row per element: its name, the light and dark wells, and a reset button
    /// while it differs from the theme.
    private var colorGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(MarkdownColors.Mode.allCases, id: \.self) { mode in
                    Text(MarkdownColorsLabels.label(mode))
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.center)
                }
                Color.clear.frame(width: 1, height: 1)
            }
            ForEach(MarkdownColorsLabels.groups) { group in
                GridRow {
                    Text(group.title)
                        .uiFont(.headline)
                        .padding(.top, 4)
                        .gridCellColumns(4)
                }
                ForEach(group.elements, id: \.self) { element in
                    colorRow(element)
                }
            }
        }
    }

    private func colorRow(_ element: MarkdownColors.Element) -> some View {
        let custom = model.markdownColors.isCustom(element)
        return GridRow {
            Text(MarkdownColorsLabels.label(element))
                .foregroundStyle(custom ? .primary : .secondary)
                .padding(.leading, 10)
            ForEach(MarkdownColors.Mode.allCases, id: \.self) { mode in
                ColorPicker(MarkdownColorsLabels.label(mode), selection: model.markdownColorBinding(element, mode))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("markdownColor.\(element.rawValue).\(mode.rawValue)")
            }
            Button("Use Theme Color", systemImage: "arrow.uturn.backward") {
                model.markdownColors.resetColor(element)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Use the theme's colors")
            .opacity(custom ? 1 : 0)
            .disabled(!custom)
        }
    }
}
