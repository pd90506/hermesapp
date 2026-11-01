import Foundation
import HermesProtocol

/// A ready-made job with a few blanks to fill, from `GET /api/cron/blueprints?profile=`
/// (`hermes_cli/web_routers/cron.py:891-900`, `cron/blueprint_catalog.py`). Filling it in
/// creates a real job (`POST /api/cron/blueprints/instantiate`). Desktop offers them under
/// "Start from" in its New Cron Job dialog (`apps/desktop/src/app/cron/index.tsx:1409-1428`).
public struct CronBlueprint: Sendable, Hashable, Identifiable, Decodable {
    public struct Field: Sendable, Hashable, Identifiable, Decodable {
        public enum Kind: String, Sendable, Decodable {
            case text, time, weekdays, `enum`
        }

        public var name: String
        public var kind: Kind
        public var label: String
        public var defaultValue: String?
        public var options: [String]
        public var isOptional: Bool
        public var help: String

        public var id: String { name }

        /// The deliver blank: offered as the job editor's delivery toggles, not its listed options.
        public var isDeliver: Bool { name == "deliver" }

        public init(name: String, kind: Kind, label: String, defaultValue: String? = nil, options: [String] = [],
                    isOptional: Bool = false, help: String = "") {
            self.name = name
            self.kind = kind
            self.label = label
            self.defaultValue = defaultValue
            self.options = options
            self.isOptional = isOptional
            self.help = help
        }

        enum CodingKeys: String, CodingKey {
            case name, type, label, options, optional, help
            case defaultValue = "default"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            // An unknown kind is filled in as text, as Desktop's control falls back to.
            kind = (try? c.decodeIfPresent(Kind.self, forKey: .type)) ?? .text
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? name
            defaultValue = try? c.decodeIfPresent(String.self, forKey: .defaultValue)
            options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
            isOptional = (try? c.decodeIfPresent(Bool.self, forKey: .optional)) ?? false
            help = (try? c.decodeIfPresent(String.self, forKey: .help)) ?? ""
        }
    }

    public var key: String
    public var title: String
    public var description: String
    public var fields: [Field]
    /// The plugin that registered it, for a plugin's blueprint.
    public var plugin: String?

    public var id: String { key }

    public init(key: String, title: String, description: String = "", fields: [Field] = [], plugin: String? = nil) {
        self.key = key
        self.title = title
        self.description = description
        self.fields = fields
        self.plugin = plugin
    }

    enum CodingKeys: String, CodingKey {
        case key, title, description, fields, plugin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? key
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        fields = (try? c.decodeIfPresent([Field].self, forKey: .fields)) ?? []
        plugin = try? c.decodeIfPresent(String.self, forKey: .plugin)
    }

    /// Each blank's default. The deliver blank's `origin` (the chat a gateway job came
    /// from) means nothing to an app, so it starts on `local` (`initialBlueprintValues`,
    /// `apps/desktop/src/app/cron/blueprints.tsx:22-31`).
    public var initialValues: [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            let seeded = field.defaultValue ?? ""
            values[field.name] = field.isDeliver && (seeded.isEmpty || seeded == "origin") ? "local" : seeded
        }
        return values
    }
}
