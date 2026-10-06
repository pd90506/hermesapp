import Foundation
import HermesProtocol

/// One pickable model: a model id under the provider that serves it.
public struct ModelChoice: Sendable, Hashable, Identifiable {
    /// Provider slug, sent as `--provider`.
    public var provider: String
    public var model: String

    public var id: String { "\(provider)\u{0}\(model)" }

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// The model picker's data, built from a `model.options` answer.
public struct ModelCatalog: Sendable, Hashable {
    /// Providers that offer at least one model, in the server's order (it
    /// already sorts them canonically, `hermes_cli/inventory.py:141-142`). Desktop treats a
    /// catalog with no models as nothing to pick (`model-options.ts:131-133`).
    public var providers: [ModelOptionProvider]
    /// The gateway's view of the current pair; the session's own
    /// `session.info` wins over it (`model-status-label.ts:1-33`).
    public var model: String?
    public var provider: String?

    public init(_ result: ModelOptionsResult) {
        providers = result.providers.filter { !$0.models.isEmpty }
        model = result.model.flatMap { $0.isEmpty ? nil : $0 }
        provider = result.provider.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var isEmpty: Bool { providers.isEmpty }

    /// The catalog row's capabilities for a model; `nil` when the catalog does not list it.
    public func capabilities(model: String, provider: String?) -> ModelCapabilities? {
        let rows = providers.filter { provider == nil || $0.slug.caseInsensitiveCompare(provider!) == .orderedSame }
        for row in rows {
            if let caps = row.capabilities?[model] { return caps }
        }
        return nil
    }

    /// The provider display name for a slug.
    public func providerName(_ slug: String) -> String {
        providers.first { $0.slug.caseInsensitiveCompare(slug) == .orderedSame }?.name ?? slug
    }
}

/// Human model names for the composer, after Desktop's
/// `apps/desktop/src/lib/model-status-label.ts` (`modelDisplayParts`): drops a
/// vendor prefix and a date pin, dots Anthropic versions and keeps variants
/// (`-fast`, `[1m]`) visible so distinct ids never read the same. GGUF quant
/// tags are not split out.
public enum ModelLabel {
    public static func displayName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "No model" }
        var base = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        var tags: [String] = []

        for (suffix, tag) in variantTags where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            tags.append(tag)
            break
        }
        if let range = base.range(of: #"\[(\d+[mMkK])\]$"#, options: .regularExpression) {
            tags.append(base[range].dropFirst().dropLast().uppercased())
            base.removeSubrange(range)
        }
        if let range = base.range(of: #"-\d{8}$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }

        let name = prettify(base)
        let full = name.isEmpty ? trimmed : name
        return tags.isEmpty ? full : "\(full) · \(tags.joined(separator: " "))"
    }

    private static let variantTags: [(String, String)] = [
        ("-fast", "Fast"), ("-flash", "Flash"), ("-thinking", "Thinking"),
        ("-preview", "Preview"), ("-latest", "Latest"),
    ]

    private static let vendorCasing: [(String, String)] = [
        ("Deepseek", "DeepSeek"), ("Glm", "GLM"), ("Minimax", "MiniMax"), ("Openai", "OpenAI"),
        ("Ernie", "ERNIE"), ("Mimo", "MiMo"), ("Bge", "BGE"), ("Vl", "VL"), ("It", "IT"),
        ("Fp8", "FP8"), ("Ai", "AI"),
    ]

    private static func prettify(_ base: String) -> String {
        let lower = base.lowercased()
        if lower.hasPrefix("claude-") {
            // `opus-5-5` → "Opus 5.5": hyphens between digits are version dots.
            let rest = String(base.dropFirst("claude-".count))
                .replacingOccurrences(of: #"(\d)-(?=\d)"#, with: "$1.", options: .regularExpression)
                .replacingOccurrences(of: "-", with: " ")
            return vendorCase(titleCase(rest))
        }
        if lower.hasPrefix("gpt-") {
            return "GPT-" + base.dropFirst("gpt-".count)
        }
        return vendorCase(titleCase(base.replacingOccurrences(of: "-", with: " ")))
    }

    /// Upper-cases the first letter of every word, like JavaScript's `\b\w`.
    private static func titleCase(_ text: String) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            let isWord = character.isLetter || character.isNumber || character == "_"
            result.append(atWordStart && isWord ? Character(character.uppercased()) : character)
            atWordStart = !isWord
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func vendorCase(_ text: String) -> String {
        // Parameter counts: "8b" → "8B", "A22b" → "A22B".
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices {
            let word = words[index]
            if word.range(of: #"^[aA]?\d+(\.\d+)?[bB]$"#, options: .regularExpression) != nil {
                words[index] = word.uppercased()
            } else if let replacement = vendorCasing.first(where: { $0.0 == word })?.1 {
                words[index] = replacement
            }
        }
        return words.joined(separator: " ")
    }
}
