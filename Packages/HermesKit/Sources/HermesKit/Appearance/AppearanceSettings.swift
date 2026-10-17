import Foundation

/// The Appearance settings: light, dark or the system's look, and three text sizes.
///
/// `[client choice]` Kept by the app, across launches. A size the user never changed
/// is `nil` and follows the platform default the app passes in, so a later change to
/// that default reaches them too.
public struct AppearanceSettings: Sendable, Hashable, Codable {
    public enum Theme: String, Sendable, Hashable, Codable, CaseIterable {
        case system, light, dark
    }

    /// What a size applies to.
    public enum TextKind: String, Sendable, Hashable, Codable, CaseIterable {
        /// Sidebar, lists, tool rows, notices, settings.
        case ui
        /// Messages: replies, reasoning, the user's own and the composer.
        case content
        /// Code blocks in replies.
        case code
    }

    /// The sizes the steppers allow, in points.
    public static let sizeRange: ClosedRange<Double> = 9...32

    public var theme: Theme
    private var sizes: [TextKind: Double]

    public init(theme: Theme = .system) {
        self.theme = theme
        self.sizes = [:]
    }

    /// The size in points: the user's, or `platformDefault`.
    public func size(_ kind: TextKind, default platformDefault: Double) -> Double {
        sizes[kind] ?? platformDefault
    }

    /// Whether the user changed this size.
    public func isCustom(_ kind: TextKind) -> Bool { sizes[kind] != nil }

    /// Sets a size, clamped to `sizeRange` and rounded to the point. Setting the
    /// platform default forgets the size, so it follows the default again.
    public mutating func setSize(_ kind: TextKind, _ size: Double, default platformDefault: Double) {
        let clamped = min(max(size.rounded(), Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        sizes[kind] = clamped == platformDefault ? nil : clamped
    }

    public mutating func resetSize(_ kind: TextKind) { sizes[kind] = nil }

    /// Everything back to the defaults.
    public mutating func reset() { self = Self() }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case theme, sizes }

    /// Saved by another version: an unknown theme is the system's, unknown kinds and
    /// out-of-range sizes are dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let theme = try? container.decodeIfPresent(String.self, forKey: .theme)
        self.theme = theme.flatMap(Theme.init(rawValue:)) ?? .system
        let raw = (try? container.decodeIfPresent([String: Double].self, forKey: .sizes)) ?? [:]
        var sizes: [TextKind: Double] = [:]
        for (key, value) in raw {
            guard let kind = TextKind(rawValue: key), Self.sizeRange.contains(value) else { continue }
            sizes[kind] = value
        }
        self.sizes = sizes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme, forKey: .theme)
        try container.encode(Dictionary(uniqueKeysWithValues: sizes.map { ($0.key.rawValue, $0.value) }), forKey: .sizes)
    }
}
