import Foundation

/// A colour in sRGB, kept to 8 bits a channel so a colour the user picked survives a
/// save and load unchanged. Saved as `#RRGGBB` or `#RRGGBBAA`.
public struct RGBAColor: Sendable, Hashable, Codable, CustomStringConvertible {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// Each channel clamped to 0…1 and rounded to the nearest 1/255.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func channel(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return (min(max(value, 0), 1) * 255).rounded() / 255
        }
        self.red = channel(red)
        self.green = channel(green)
        self.blue = channel(blue)
        self.alpha = channel(alpha)
    }

    /// `#RRGGBB` or `#RRGGBBAA`, the `#` optional; nil for anything else.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        func byte(_ shift: UInt32) -> Double { Double(full >> shift & 0xFF) / 255 }
        self.init(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
    }

    /// `#RRGGBB` when opaque, else `#RRGGBBAA`.
    public var hex: String {
        let bytes = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        let opaque = bytes[3] == 255
        return "#" + (opaque ? bytes.prefix(3) : bytes[...]).map { String(format: "%02X", $0) }.joined()
    }

    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let color = RGBAColor(hex: string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not a #RRGGBB(AA) colour: \(string)"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The colours of Markdown in messages: headings, links, code, quotes and tables, each
/// with a colour for light mode and one for dark.
///
/// `[client choice]` Kept by the app, across launches. Hermes Desktop has no per-element
/// Markdown colours; its themes colour the transcript as a whole
/// (`apps/desktop/src/themes/presets.ts`). The presets here borrow those themes' palettes,
/// and the default borrows Desktop's default theme (Nous) and its blue.
///
/// The user starts from a preset and may change single colours; a colour the user never
/// changed follows the preset.
public struct MarkdownColors: Sendable, Hashable, Codable {
    public enum Element: String, Sendable, Hashable, Codable, CaseIterable {
        case heading, bold, link
        case inlineCode, inlineCodeBackground, codeBlockBackground
        case quoteBar, quoteText, quoteBackground
        case tableHeaderBackground, tableHeaderText, tableBorder, tableStripe
    }

    public enum Mode: String, Sendable, Hashable, Codable, CaseIterable {
        case light, dark
    }

    /// A colour for each mode.
    public struct Pair: Sendable, Hashable {
        public var light: RGBAColor
        public var dark: RGBAColor

        public init(light: RGBAColor, dark: RGBAColor) {
            self.light = light
            self.dark = dark
        }

        public subscript(mode: Mode) -> RGBAColor {
            get { mode == .light ? light : dark }
            set { if mode == .light { light = newValue } else { dark = newValue } }
        }
    }

    public enum Preset: String, Sendable, Hashable, Codable, CaseIterable {
        /// Hermes Desktop's default theme: GitHub's neutrals and Nous blue.
        case nous
        case github, catppuccin, everforest, solarized
        /// No colour of its own: the system's text greys and link blue, as messages
        /// looked before these settings.
        case plain
    }

    public private(set) var preset: Preset
    private var custom: [Element: [Mode: RGBAColor]]

    public init(preset: Preset = .nous) {
        self.preset = preset
        self.custom = [:]
    }

    /// The colour of `element` in `mode`: the user's, or the preset's.
    public func color(_ element: Element, _ mode: Mode) -> RGBAColor {
        custom[element]?[mode] ?? Self.palette(preset)[element][mode]
    }

    public func colors(_ element: Element) -> Pair {
        Pair(light: color(element, .light), dark: color(element, .dark))
    }

    /// Whether the user changed either of this element's colours.
    public func isCustom(_ element: Element) -> Bool { custom[element]?.isEmpty == false }

    /// Whether the user changed any colour.
    public var hasCustomColors: Bool { custom.values.contains { !$0.isEmpty } }

    /// Sets one colour. The preset's own colour forgets it, so it follows the preset again.
    public mutating func setColor(_ color: RGBAColor, for element: Element, _ mode: Mode) {
        var colors = custom[element] ?? [:]
        colors[mode] = color == Self.palette(preset)[element][mode] ? nil : color
        custom[element] = colors.isEmpty ? nil : colors
    }

    /// Both of the element's colours back to the preset's.
    public mutating func resetColor(_ element: Element) { custom[element] = nil }

    /// Switches to `preset` and forgets the colours the user changed, so the preset shows
    /// as it is.
    public mutating func choose(_ preset: Preset) {
        self.preset = preset
        custom = [:]
    }

    // MARK: Palettes

    /// Every element's colours in `preset`.
    public static func palette(_ preset: Preset) -> Palette {
        switch preset {
        case .nous: nous
        case .github: github
        case .catppuccin: catppuccin
        case .everforest: everforest
        case .solarized: solarized
        case .plain: plain
        }
    }

    /// A preset's colours, one pair per element.
    public struct Palette: Sendable {
        let pairs: [Element: Pair]

        public subscript(element: Element) -> Pair { pairs[element]! }

        /// Hex pairs, light then dark, for every element.
        init(_ hex: [Element: (String, String)]) {
            precondition(Set(hex.keys) == Set(Element.allCases), "a palette names every element")
            pairs = hex.mapValues { Pair(light: RGBAColor(hex: $0.0)!, dark: RGBAColor(hex: $0.1)!) }
        }
    }

    /// Desktop's default theme (`nousTheme`): GitHub's neutrals, Nous blue `#0053FD`
    /// (`#4A84FE` in dark), tinted surfaces for quotes, code and tables.
    static let nous = Palette([
        .heading: ("#0B3BA8", "#8DB2FF"),
        .bold: ("#1F2328", "#F0F6FC"),
        .link: ("#0053FD", "#4A84FE"),
        .inlineCode: ("#B42D5B", "#FF8FB4"),
        .inlineCodeBackground: ("#B42D5B14", "#FF8FB41F"),
        .codeBlockBackground: ("#0053FD0D", "#4A84FE17"),
        .quoteBar: ("#0053FDB3", "#4A84FECC"),
        .quoteText: ("#57606A", "#9EA7B3"),
        .quoteBackground: ("#0053FD0A", "#4A84FE12"),
        .tableHeaderBackground: ("#0053FD1A", "#4A84FE29"),
        .tableHeaderText: ("#0B3BA8", "#B5CDFF"),
        .tableBorder: ("#0053FD33", "#4A84FE47"),
        .tableStripe: ("#0053FD08", "#4A84FE0D"),
    ])

    /// GitHub Light Default and Dark Default (`githubTheme`).
    static let github = Palette([
        .heading: ("#1F2328", "#F0F6FC"),
        .bold: ("#1F2328", "#F0F6FC"),
        .link: ("#0969DA", "#4493F8"),
        .inlineCode: ("#1F2328", "#F0F6FC"),
        .inlineCodeBackground: ("#818B9833", "#656C7666"),
        .codeBlockBackground: ("#818B9817", "#0104094D"),
        .quoteBar: ("#D1D9E0", "#3D444D"),
        .quoteText: ("#59636E", "#9198A1"),
        .quoteBackground: ("#00000000", "#00000000"),
        .tableHeaderBackground: ("#818B9817", "#6E768126"),
        .tableHeaderText: ("#1F2328", "#F0F6FC"),
        .tableBorder: ("#D1D9E0", "#3D444D"),
        .tableStripe: ("#818B980F", "#6E76811A"),
    ])

    /// Catppuccin Latte and Mocha (`catppuccinTheme`).
    static let catppuccin = Palette([
        .heading: ("#8839EF", "#CBA6F7"),
        .bold: ("#4C4F69", "#CDD6F4"),
        .link: ("#1E66F5", "#89B4FA"),
        .inlineCode: ("#40A02B", "#A6E3A1"),
        .inlineCodeBackground: ("#CCD0DA99", "#313244CC"),
        .codeBlockBackground: ("#E6E9EFCC", "#181825B3"),
        .quoteBar: ("#7287FD", "#B4BEFE"),
        .quoteText: ("#6C6F85", "#A6ADC8"),
        .quoteBackground: ("#7287FD0F", "#B4BEFE0F"),
        .tableHeaderBackground: ("#8839EF1A", "#CBA6F726"),
        .tableHeaderText: ("#8839EF", "#CBA6F7"),
        .tableBorder: ("#BCC0CC", "#45475A"),
        .tableStripe: ("#E6E9EF99", "#18182580"),
    ])

    /// Everforest light and dark (`everforestTheme`).
    static let everforest = Palette([
        .heading: ("#35A77C", "#A7C080"),
        .bold: ("#5C6A72", "#D3C6AA"),
        .link: ("#3A94C5", "#7FBBB3"),
        .inlineCode: ("#E66E1A", "#E69875"),
        .inlineCodeBackground: ("#F57D2617", "#E698751F"),
        .codeBlockBackground: ("#EFEBD4B3", "#232A2EB3"),
        .quoteBar: ("#8DA101", "#A7C080"),
        .quoteText: ("#829181", "#9DA9A0"),
        .quoteBackground: ("#8DA1010D", "#A7C08012"),
        .tableHeaderBackground: ("#8DA1011F", "#A7C08026"),
        .tableHeaderText: ("#5C6A72", "#D3C6AA"),
        .tableBorder: ("#E0DCC7", "#4F585E"),
        .tableStripe: ("#EFEBD480", "#2E383C80"),
    ])

    /// Solarized light and dark (`solarizedTheme`).
    static let solarized = Palette([
        .heading: ("#CB4B16", "#CB4B16"),
        .bold: ("#586E75", "#93A1A1"),
        .link: ("#268BD2", "#268BD2"),
        .inlineCode: ("#D33682", "#D33682"),
        .inlineCodeBackground: ("#EEE8D5", "#073642"),
        .codeBlockBackground: ("#EEE8D5B3", "#073642B3"),
        .quoteBar: ("#2AA198", "#2AA198"),
        .quoteText: ("#657B83", "#93A1A1"),
        .quoteBackground: ("#2AA1980F", "#2AA1980F"),
        .tableHeaderBackground: ("#EEE8D5", "#073642"),
        .tableHeaderText: ("#586E75", "#93A1A1"),
        .tableBorder: ("#E4DDC8", "#0B4452"),
        .tableStripe: ("#EEE8D580", "#07364280"),
    ])

    /// The system's label greys and link blue, without tints: messages as they looked
    /// before these settings.
    static let plain = Palette([
        .heading: ("#000000D9", "#FFFFFFD9"),
        .bold: ("#000000D9", "#FFFFFFD9"),
        .link: ("#0068DA", "#419CFF"),
        .inlineCode: ("#000000D9", "#FFFFFFD9"),
        .inlineCodeBackground: ("#00000026", "#FFFFFF26"),
        .codeBlockBackground: ("#0000000A", "#FFFFFF0A"),
        .quoteBar: ("#00000042", "#FFFFFF40"),
        .quoteText: ("#00000080", "#FFFFFF8C"),
        .quoteBackground: ("#00000000", "#00000000"),
        .tableHeaderBackground: ("#0000000F", "#FFFFFF0F"),
        .tableHeaderText: ("#000000D9", "#FFFFFFD9"),
        .tableBorder: ("#0000001A", "#FFFFFF1A"),
        .tableStripe: ("#00000000", "#00000000"),
    ])

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case preset, colors }

    /// Saved by another version: an unknown preset is the default, unknown elements and
    /// colours that don't parse are dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try? container.decodeIfPresent(String.self, forKey: .preset)
        self.preset = preset.flatMap(Preset.init(rawValue:)) ?? .nous
        let raw = (try? container.decodeIfPresent([String: [String: String]].self, forKey: .colors)) ?? [:]
        var custom: [Element: [Mode: RGBAColor]] = [:]
        for (key, modes) in raw {
            guard let element = Element(rawValue: key) else { continue }
            var colors: [Mode: RGBAColor] = [:]
            for (mode, hex) in modes {
                guard let mode = Mode(rawValue: mode), let color = RGBAColor(hex: hex) else { continue }
                colors[mode] = color
            }
            if !colors.isEmpty { custom[element] = colors }
        }
        self.custom = custom
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        let colors = Dictionary(uniqueKeysWithValues: custom.map { element, modes in
            (element.rawValue, Dictionary(uniqueKeysWithValues: modes.map { ($0.key.rawValue, $0.value.hex) }))
        })
        try container.encode(colors, forKey: .colors)
    }
}
