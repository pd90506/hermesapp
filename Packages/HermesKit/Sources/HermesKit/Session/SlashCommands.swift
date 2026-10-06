import Foundation
import HermesProtocol

/// One slash command the composer can offer.
public struct SlashCommand: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A Hermes built-in from the command registry.
        case builtIn
        /// A `quick_commands` entry from the profile's config ("User commands").
        case quick
        /// A plugin's command ("Plugin commands").
        case plugin
        /// A skill: running it sends the expanded skill as a normal prompt.
        case skill
    }

    /// With the leading slash, e.g. `/compress`.
    public var name: String
    public var description: String
    /// The catalog category (`Session`, `User commands`, …); `Skills` for skills.
    public var category: String
    public var kind: Kind
    /// `options` | `text` | `mixed` (`contracts/tools_commands.py:194-203`).
    public var argumentMode: String?
    /// Why the command cannot run from this app, or `nil` when it can.
    public var unavailableReason: String?

    public var id: String { name }
    public var isAvailable: Bool { unavailableReason == nil }

    public init(name: String, description: String, category: String, kind: Kind,
                argumentMode: String? = nil, unavailableReason: String? = nil) {
        self.name = name
        self.description = description
        self.category = category
        self.kind = kind
        self.argumentMode = argumentMode
        self.unavailableReason = unavailableReason
    }

    /// Does the composer text run as a slash command rather than a prompt?
    /// Desktop's `SLASH_COMMAND_RE` (`apps/shared/src/slash.ts:11`): `/name`
    /// followed by whitespace or the end, so `/usr/bin` is a normal prompt.
    public static func isCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let token = trimmed.dropFirst().prefix { !$0.isWhitespace }
        return !token.contains("/")
    }

    /// Splits `/Name  some args` into (`name`, `some args`): the name is
    /// lower-cased and loses its leading slashes; the argument keeps interior
    /// whitespace (`parseSlashCommand`, `apps/shared/src/slash.ts:35-39`).
    public static func parse(_ text: String) -> (name: String, argument: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.drop { $0 == "/" }
        let name = body.prefix { !$0.isWhitespace }
        let argument = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.lowercased(), argument)
    }

    /// Commands that Desktop runs as client-side actions or pickers and never
    /// sends to the gateway (`apps/desktop/src/lib/desktop-slash-commands.ts:189-325`),
    /// minus the ones the package runs itself (`ChatSession.runSlash`: `/btw`, `/title`,
    /// `/stop`, `/compress`, `/bg`, `/save`, `/status`). They need UI and come back to
    /// the app as `SlashOutcome.clientAction`.
    public static let clientActions: Set<String> = [
        "new", "reset", "clear", "branch", "fork", "yolo", "reasoning", "wake", "handoff", "profile", "skin",
        "help", "commands", "browser", "journey", "learning", "memory-graph", "model", "resume", "sessions",
        "switch", "pet", "hatch", "generate-pet",
    ]

    /// Desktop's local `desktopSubcommands` (`desktop-slash-commands.ts:314-325`),
    /// used until a catalog says otherwise: `/skills` only reviews staged writes.
    static let localSubcommands: [String: [String]] = ["/skills": ["pending", "approve", "reject", "diff", "approval"]]

    /// Catalog `desktop` values meaning "not available in a GUI client"
    /// (`desktop-slash-commands.ts:440-483`).
    static let unavailableDispositions: [String: String] = [
        "terminal": "only works in the terminal",
        "messaging": "only works on a messaging platform",
        "settings": "is managed in settings",
        "advanced": "is not available in this app",
        "composer-voice": "needs voice input",
    ]
}

/// The commands available in a session (`commands.catalog`).
public struct SlashCatalog: Sendable, Hashable {
    /// Category order as the gateway sends it; skills last.
    public var commands: [SlashCommand]
    /// Discovery problems the gateway reported (e.g. skills unavailable).
    public var warning: String?
    /// Alias → canonical name, both with a slash (`canon`).
    var canon: [String: String] = [:]
    /// Per-command metadata, hidden commands included (`commands`).
    var meta: [String: CommandsCatalogResult.Meta] = [:]

    public init(commands: [SlashCommand], warning: String? = nil) {
        self.commands = commands
        self.warning = warning
    }

    /// The canonical `/name` for a typed name or alias.
    public func canonicalName(_ name: String) -> String {
        let key = name.hasPrefix("/") ? name.lowercased() : "/" + name.lowercased()
        return canon[key] ?? key
    }

    /// Why `/name argument` must not run from this app, or `nil` when it may.
    /// Mirrors Desktop's exec gate (`desktop-slash-commands.ts:551-587,705-720`):
    /// a command the catalog marks unavailable in a GUI runs only for an allowed
    /// subcommand, and a command narrowed by `desktop_subcommands` needs an
    /// allowed first argument token.
    public func refusal(for name: String, argument: String) -> String? {
        let canonical = canonicalName(name)
        let display = name.hasPrefix("/") ? name : "/" + name
        let entry = meta[canonical]
        let allowed = entry?.desktopSubcommands ?? SlashCommand.localSubcommands[canonical]
        let first = argument.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        if let reason = Self.unavailableReason(display, meta: entry),
            allowed?.contains(where: { $0.lowercased() == first }) != true
        {
            return reason
        }
        guard let allowed else { return nil }
        if allowed.isEmpty { return "\(display) is not available in this app — use the terminal for it." }
        if first.isEmpty { return "\(display) needs a subcommand here: \(allowed.joined(separator: ", "))." }
        guard allowed.contains(where: { $0.lowercased() == first }) else {
            return "\(display) \(first) is not available in this app — use the terminal for it. "
                + "Available here: \(allowed.joined(separator: ", "))."
        }
        return nil
    }

    /// Builds the list the way Desktop's popover does
    /// (`use-slash-completions.ts:173-215`): the categorized registry, quick and
    /// plugin commands, then every skill from `pairs` under "Skills". Commands
    /// the catalog marks `hidden` are left out.
    public init(_ result: CommandsCatalogResult) {
        var seen = Set<String>()
        var commands: [SlashCommand] = []
        let skillNames = Set((result.skills ?? [:]).keys)
        for category in result.categories ?? [] {
            for pair in category.pairs ?? [] {
                guard let name = pair.first, !name.isEmpty, seen.insert(name).inserted else { continue }
                let meta = result.commands?[name]
                if meta?.desktop == "hidden" { continue }
                let kind: SlashCommand.Kind
                switch category.name {
                case "User commands": kind = .quick
                case "Plugin commands": kind = .plugin
                default: kind = skillNames.contains(name) ? .skill : .builtIn
                }
                // Partly available when some subcommands are allowed (e.g. `/skills pending`).
                let reason = (meta?.desktopSubcommands ?? []).isEmpty ? Self.unavailableReason(name, meta: meta) : nil
                commands.append(SlashCommand(name: name, description: pair.dropFirst().first ?? "",
                                             category: category.name, kind: kind,
                                             argumentMode: meta?.argumentMode, unavailableReason: reason))
            }
        }
        // Skills ride `pairs` only (`methods_tools.py:489-500`).
        for pair in result.pairs ?? [] {
            guard let name = pair.first, skillNames.contains(name), seen.insert(name).inserted else { continue }
            commands.append(SlashCommand(name: name, description: pair.dropFirst().first ?? "", category: "Skills",
                                         kind: .skill))
        }
        self.init(commands: commands, warning: (result.warning ?? "").isEmpty ? nil : result.warning)
        for (alias, canonical) in result.canon ?? [:] { canon[alias.lowercased()] = canonical.lowercased() }
        for (name, entry) in result.commands ?? [:] { meta[name.lowercased()] = entry }
    }

    /// A listed command by name or alias.
    public func command(named name: String) -> SlashCommand? {
        let key = canonicalName(name)
        return commands.first { $0.name.lowercased() == key }
    }

    static func unavailableReason(_ name: String, meta: CommandsCatalogResult.Meta?) -> String? {
        guard let disposition = meta?.desktop, let reason = SlashCommand.unavailableDispositions[disposition] else {
            return nil
        }
        return "\(name) \(reason)."
    }
}

/// Completions for a typed `/` prefix (`complete.slash`).
public struct SlashCompletions: Sendable, Hashable {
    public var items: [SlashCompletionItem]
    /// The column an accepted item replaces from.
    public var replaceFrom: Int
    /// The composer text the completions are for.
    public var text: String

    public init(_ result: CompleteSlashResult, text: String) {
        self.items = result.items
        self.replaceFrom = result.replaceFrom ?? 1
        self.text = text
    }

    /// The composer text after accepting `item`. Argument-stage items carry
    /// only the argument stub and keep the command in front of it
    /// (`use-slash-completions.ts:224-252`); command-stage items are the whole `/command`.
    public func applying(_ item: SlashCompletionItem) -> String {
        guard replaceFrom > 1 else { return item.text }
        return String(text.prefix(replaceFrom)) + item.text
    }
}

/// What running a slash command did.
public enum SlashOutcome: Sendable, Hashable {
    /// Text output, also appended to the transcript as a system row.
    case output(String)
    /// A prompt was submitted (a skill, a bundle, or a command that composes a
    /// prompt). `display` is what the transcript shows instead of the expanded text.
    case submitted(display: String)
    /// Put this text into the composer for editing (e.g. `/undo`).
    case prefill(String)
    /// Handled by the package (`/btw`, `/title`, `/stop`); the transcript shows the effect.
    case handled
    /// A Desktop client-side action or picker (`/new`, `/model`, …): the app
    /// decides what to do; nothing was sent to the gateway. `name` is the
    /// command's canonical name (no slash) when the loaded catalog maps the typed
    /// alias to one, else the name as typed.
    case clientAction(name: String, argument: String)
    /// The command cannot run from this app; nothing was sent.
    case unavailable(String)
}
