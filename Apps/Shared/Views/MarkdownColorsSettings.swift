import HermesKit
import SwiftUI

/// The names Settings ▸ Markdown shows for the Markdown colours (`MarkdownColors`).
enum MarkdownColorsLabels {
    struct Group: Identifiable {
        let title: String
        let elements: [MarkdownColors.Element]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Text", elements: [.heading, .bold, .link]),
        Group(title: "Code", elements: [.inlineCode, .inlineCodeBackground, .codeBlockBackground]),
        Group(title: "Quotes", elements: [.quoteBar, .quoteText, .quoteBackground]),
        Group(title: "Tables", elements: [.tableHeaderBackground, .tableHeaderText, .tableBorder, .tableStripe]),
    ]

    /// The element's name within its group.
    static func label(_ element: MarkdownColors.Element) -> String {
        switch element {
        case .heading: "Headings"
        case .bold: "Bold text"
        case .link: "Links"
        case .inlineCode: "Inline code"
        case .inlineCodeBackground: "Inline code background"
        case .codeBlockBackground: "Code block background"
        case .quoteBar: "Bar"
        case .quoteText: "Text"
        case .quoteBackground: "Background"
        case .tableHeaderBackground: "Header row"
        case .tableHeaderText: "Header text"
        case .tableBorder: "Borders"
        case .tableStripe: "Striped rows"
        }
    }

    static func label(_ preset: MarkdownColors.Preset) -> String {
        switch preset {
        case .nous: "Nous (Desktop default)"
        case .github: "GitHub"
        case .catppuccin: "Catppuccin"
        case .everforest: "Everforest"
        case .solarized: "Solarized"
        case .plain: "Plain"
        }
    }

    static func label(_ mode: MarkdownColors.Mode) -> String {
        switch mode {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// A short reply with every coloured element, rendered as messages are, in light or dark
/// whatever the app's look.
struct MarkdownColorsPreview: View {
    let scheme: ColorScheme

    static let sample = """
        ### A heading

        Text with **bold words**, a [link](https://example.com) and `inline code`.

        > A quote stands apart from the reply.

        | Name | Value |
        |------|------:|
        | Alpha | 1 |
        | Beta | 2 |
        | Gamma | 3 |

        ```swift
        let answer = 42
        ```
        """

    var body: some View {
        MarkdownView(text: Self.sample, isStreaming: false)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
            .environment(\.colorScheme, scheme)
            .environment(\.markdownPreviewScheme, scheme)
            .accessibilityIdentifier("markdownColorsPreview")
    }
}

extension AppModel {
    /// One colour of one element, for a colour picker; a colour the preset already has
    /// is forgotten, so the element follows the preset again.
    func markdownColorBinding(_ element: MarkdownColors.Element, _ mode: MarkdownColors.Mode) -> Binding<Color> {
        Binding(
            get: { Color(self.markdownColors.color(element, mode)) },
            set: { self.markdownColors.setColor(RGBAColor($0), for: element, mode) })
    }

    /// The preset; choosing one forgets the colours the user changed.
    var markdownPresetBinding: Binding<MarkdownColors.Preset> {
        Binding(
            get: { self.markdownColors.preset },
            set: { self.markdownColors.choose($0) })
    }
}

#if os(iOS)
/// Settings ▸ Appearance ▸ Markdown on iOS: the theme, a preview, and a light and a dark
/// colour for each element. The macOS Settings window has `MarkdownSettingsPane`.
struct MarkdownColorsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: model.markdownPresetBinding) {
                    ForEach(MarkdownColors.Preset.allCases, id: \.self) { preset in
                        Text(MarkdownColorsLabels.label(preset)).tag(preset)
                    }
                }
                .accessibilityIdentifier("markdownPreset")
            } footer: {
                Text("The themes are Hermes Desktop's. Choosing one clears the colors you changed.")
            }

            Section("Preview") {
                MarkdownColorsPreview(scheme: colorScheme)
            }

            ForEach(MarkdownColorsLabels.groups) { group in
                Section {
                    ForEach(group.elements, id: \.self) { element in
                        HStack {
                            Text(MarkdownColorsLabels.label(element))
                            Spacer()
                            ForEach(MarkdownColors.Mode.allCases, id: \.self) { mode in
                                ColorPicker(MarkdownColorsLabels.label(mode),
                                            selection: model.markdownColorBinding(element, mode))
                                    .labelsHidden()
                            }
                        }
                        .foregroundStyle(model.markdownColors.isCustom(element) ? .primary : .secondary)
                        .accessibilityIdentifier("markdownColor.\(element.rawValue)")
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if group.id == MarkdownColorsLabels.groups.last?.id {
                        Text("Left: light mode. Right: dark mode.")
                    }
                }
            }

            Section {
                Button("Restore Default Colors") { model.markdownColors = MarkdownColors() }
                    .disabled(model.markdownColors == MarkdownColors())
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Markdown")
    }
}
#endif
