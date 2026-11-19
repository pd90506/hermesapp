import Foundation
import Testing

@testable import HermesKit

/// `Packages/fixtures/appearance-themes.json`: every theme's accent, surfaces and Markdown
/// colours, and how the Appearance settings load and clamp. The desktop app's TypeScript
/// core checks the same file (`Packages/hermes-core/tests/appearance.test.ts`) and its
/// theme stylesheet is generated from it (`Apps/Desktop/electron/scripts/export-themes.mjs`),
/// so the three apps draw the same colours.
///
/// When a theme changes on purpose: run this suite with `HERMES_EXPORT_FIXTURES=1`,
/// which rewrites the file's colours from HermesKit, then the export script.
@Suite struct AppearanceFixtureTests {
    static let url = SharedFixtureTests.directory.appendingPathComponent("appearance-themes.json")

    static func hex(_ pair: MarkdownColors.Pair?) -> Any {
        guard let pair else { return NSNull() }
        return ["light": pair.light.hex, "dark": pair.dark.hex]
    }

    static func surfaces(_ surfaces: ThemeSurfaces) -> [String: Any] {
        ["frame": hex(surfaces.frame), "chrome": hex(surfaces.chrome), "chat": hex(surfaces.chat),
         "composer": hex(surfaces.composer), "selection": hex(surfaces.selection), "userBubble": hex(surfaces.userBubble)]
    }

    static func pair(_ object: Any?) -> MarkdownColors.Pair? {
        guard let object = object as? [String: String], let light = object["light"].flatMap(RGBAColor.init(hex:)),
              let dark = object["dark"].flatMap(RGBAColor.init(hex:)) else { return nil }
        return MarkdownColors.Pair(light: light, dark: dark)
    }

    /// HermesKit's colours in the fixture's shape.
    static func themes() -> [[String: Any]] {
        ColorTheme.allCases.map { theme in
            let palette = MarkdownColors.palette(theme)
            var markdown: [String: Any] = [:]
            for element in MarkdownColors.Element.allCases { markdown[element.rawValue] = hex(palette[element]) }
            return ["theme": theme.rawValue, "accent": hex(theme.accent), "surfaces": surfaces(theme.surfaces),
                    "markdown": markdown]
        }
    }

    /// A JSON number, read as an Int or a Double (Linux's Foundation keeps them apart).
    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    static func load() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The same JSON, whatever the key order.
    static func same(_ a: Any, _ b: Any) throws -> Bool {
        let options: JSONSerialization.WritingOptions = [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: a, options: options)
            == JSONSerialization.data(withJSONObject: b, options: options)
    }

    @Test func themesMatchHermesKit() throws {
        var fixture = try Self.load()
        let tinted = try #require(fixture["tintedPlain"] as? [[String: Any]])
        let computedTinted: [[String: Any]] = try tinted.map { item in
            let accent = try #require(Self.pair(item["accent"]))
            return ["accent": Self.hex(accent), "surfaces": Self.surfaces(ColorTheme.plain.surfaces(accent: accent))]
        }
        if ProcessInfo.processInfo.environment["HERMES_EXPORT_FIXTURES"] == "1" {
            fixture["themes"] = Self.themes()
            fixture["tintedPlain"] = computedTinted
            let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
            try (data + Data("\n".utf8)).write(to: Self.url)
            return
        }
        let saved = try #require(fixture["themes"] as? [[String: Any]])
        let computed = Self.themes()
        #expect(saved.count == computed.count)
        for (savedTheme, theme) in zip(saved, computed) {
            #expect(try Self.same(savedTheme, theme), "\(theme["theme"] ?? "")")
        }
        for (savedItem, item) in zip(tinted, computedTinted) {
            #expect(try Self.same(savedItem, item))
        }
    }

    @Test func appearanceSettingsLoad() throws {
        let fixture = try Self.load()
        let cases = try #require(fixture["appearanceSettings"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let json = try JSONSerialization.data(withJSONObject: try #require(item["json"]))
            let decoded = try JSONSerialization.data(withJSONObject: try #require(item["decoded"]))
            let loaded = try JSONDecoder().decode(AppearanceSettings.self, from: json)
            #expect(loaded == (try JSONDecoder().decode(AppearanceSettings.self, from: decoded)), "\(item)")
        }
    }

    @Test func textSizesClamp() throws {
        let fixture = try Self.load()
        let cases = try #require(fixture["setSize"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let kind = try #require((item["kind"] as? String).flatMap(AppearanceSettings.TextKind.init(rawValue:)))
            let size = try #require(Self.number(item["size"]))
            let platformDefault = try #require(Self.number(item["platformDefault"]))
            var settings = AppearanceSettings()
            settings.setSize(kind, size, default: platformDefault)
            if let saved = Self.number(item["saved"]) {
                #expect(settings.isCustom(kind) && settings.size(kind, default: platformDefault) == saved, "\(item)")
            } else {
                #expect(!settings.isCustom(kind), "\(item)")
            }
        }
    }
}
