import Foundation
import HermesProtocol

/// What the app does with a session row's `source`, the surface Hermes stored it under
/// (`cli`, `tui`, `desktop`, `telegram`, `cron`, …): which sources the session lists
/// hide. Kept across launches.
public struct SessionSourceSettings: Sendable, Hashable, Codable {
    /// The `source` this app's sessions carry, on `session.create`, `session.resume` and
    /// Fork's `session.branch_stored`: always `desktop`, as Hermes Desktop sends
    /// (`use-session-actions/index.ts:2084-2088`). Without one the gateway would store
    /// `tui` under any backend but Desktop's (`tui_gateway/server.py:1563-1573`). Not a
    /// setting (decided by the user, 2026-10-29); a `newSessionSource` key kept from
    /// older versions is ignored when decoding.
    public static let newSessionSource = "desktop"
    /// Sources whose rows have a tab of their own and never join the session list:
    /// cron runs are in the Cron Jobs tab, as Desktop's recents leave them to its cron
    /// section (`SIDEBAR_EXCLUDED_SOURCES`, `use-session-list-actions.ts:66-73`).
    /// Decided by the user, 2026-10-29.
    public static let listedElsewhere: Set<String> = ["cron"]
    /// Sources whose rows the session list leaves out. A row without a source is
    /// always shown.
    public var hiddenSources: Set<String>

    public init(hiddenSources: Set<String> = []) {
        self.hiddenSources = hiddenSources
    }

    public func shows(_ summary: SessionSummary) -> Bool {
        guard let source = Self.normalized(summary.source) else { return true }
        return !hiddenSources.contains(source)
    }

    public func isHidden(_ source: String) -> Bool {
        hiddenSources.contains(Self.normalized(source) ?? source)
    }

    public mutating func setHidden(_ hidden: Bool, _ source: String) {
        guard let source = Self.normalized(source) else { return }
        if hidden { hiddenSources.insert(source) } else { hiddenSources.remove(source) }
    }

    /// The gateway compares sources lowercased (`methods_session.py:142`).
    public static func normalized(_ source: String?) -> String? {
        guard let value = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// A readable name for a source; unknown ones (plugin platforms) are shown as stored.
    public static func label(for source: String) -> String {
        let key = normalized(source) ?? source
        return labels[key] ?? key
    }

    /// `Platform` in `gateway/config.py:217-242`, plus the local and automatic surfaces
    /// that call `create_session` with their own name.
    private static let labels: [String: String] = [
        "desktop": "Desktop", "tui": "Terminal (TUI)", "cli": "Command line", "acp": "Editor (ACP)",
        "cron": "Scheduled (cron)", "subagent": "Subagent", "api_server": "API server",
        "webhook": "Webhook", "msgraph_webhook": "Microsoft Graph webhook", "relay": "Relay",
        "local": "Local", "unknown": "Unknown",
        "telegram": "Telegram", "discord": "Discord", "whatsapp": "WhatsApp",
        "whatsapp_cloud": "WhatsApp Cloud", "slack": "Slack", "signal": "Signal",
        "mattermost": "Mattermost", "matrix": "Matrix", "email": "Email", "sms": "SMS",
        "bluebubbles": "iMessage (BlueBubbles)", "dingtalk": "DingTalk", "feishu": "Feishu",
        "wecom": "WeCom", "wecom_callback": "WeCom (callback)", "weixin": "WeChat",
        "qqbot": "QQ", "yuanbao": "Yuanbao",
    ]
}
