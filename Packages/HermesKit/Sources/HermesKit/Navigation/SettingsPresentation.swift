/// Whether the connection settings are shown, and what may close them.
///
/// - `.required`: opened by the app because it can't work without a connection (no
///   server yet, or the launch connect failed). Clicks elsewhere don't close it, so
///   typing or pasting a URL and token can't be cut short; Done, Esc, Command-W or a
///   successful connect do.
/// - `.transient`: opened by the user (the gear). A click in the window outside the
///   settings closes it too, as Done would.
///
/// Closing never discards anything: the fields edit the app's settings directly, so
/// every way out leaves the same state Done does.
public struct SettingsPresentation: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case hidden, transient, required
    }

    public private(set) var mode: Mode

    /// At launch: required when there is no server to connect to.
    public init(hasServer: Bool) {
        mode = hasServer ? .hidden : .required
    }

    public var isShown: Bool { mode != .hidden }
    public var isRequired: Bool { mode == .required }
    public var isTransient: Bool { mode == .transient }

    /// The gear: opens the settings, or closes the ones it opened. It never turns the
    /// required settings into dismissable ones.
    public mutating func toggle() {
        switch mode {
        case .hidden: mode = .transient
        case .transient: mode = .hidden
        case .required: break
        }
    }

    /// The launch connect failed: the user has to fix the settings.
    public mutating func requireConnection() {
        mode = .required
    }

    /// A click in the window outside the settings: closes only what the user opened.
    public mutating func clickedOutside() {
        if mode == .transient { mode = .hidden }
    }

    /// Done, Esc, Command-W, or connected.
    public mutating func close() {
        mode = .hidden
    }
}
