import HermesKit
import HermesProtocol
import SwiftUI

// The sidebar's pieces, free of `AppModel` so `HermesMacTests` can host them as they are.

/// The session list's pinned top, above the scrolling list (ChatGPT style): the
/// selected profile's name (and, with several servers, its server) and the New chat
/// row. It never scrolls; rows scroll under it.
struct SessionListHeader: View {
    let title: String
    /// The profile's server, when there are several.
    var subtitle: String?
    /// The New chat row, or `nil` when no profile is selected.
    var newChat: NewChatRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Hover.rowContentInset)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let newChat {
                newChat
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }
}

/// The session list's New chat, pinned under its title: a chat with the profile
/// picked in the profile rail. Not a List row, so it can never be selected, but drawn like
/// one: the sidebar's row height and font for the user's sidebar size, the text where
/// row text starts, and the row hover pill, inset from the edges like the selection.
struct NewChatRow: View {
    var isEnabled: Bool
    /// Read by VoiceOver while the row is disabled.
    var disabledReason: String?
    var action: () -> Void

    #if os(macOS)
    @Environment(\.sidebarRowSize) private var rowSize
    #endif

    var body: some View {
        Button(action: action) {
            Label("New chat", systemImage: "square.and.pencil")
                .font(metrics.font)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: metrics.height, alignment: .leading)
                .padding(.horizontal, Hover.rowContentInset - Hover.rowInset)
                .contentShape(.rect(cornerRadius: Hover.cornerRadius))
        }
        .hoverButtonStyle(.rounded, padding: 0)
        .padding(.horizontal, Hover.rowInset)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "Starts a new chat" : disabledReason ?? "")
    }

    private var metrics: (height: CGFloat, font: Font) {
        #if os(macOS)
        Self.metrics(for: rowSize)
        #else
        (44, .body)
        #endif
    }

    #if os(macOS)
    /// A macOS sidebar List row (measured on macOS 26, checked by `HoverTests`): 24, 32
    /// or 40 pt for the small, medium and large sidebar sizes, in the matching text size.
    static func metrics(for size: SidebarRowSize) -> (height: CGFloat, font: Font) {
        switch size {
        case .small: (24, .subheadline)
        case .large: (40, .title3)
        default: (32, .body)
        }
    }
    #endif
}

/// The sidebar's Settings button: opens the settings sheet (`RootView`).
///
/// The system toolbar button, unstyled, so macOS 26 gives it the same glass circle,
/// glyph weight and hover as the sidebar toggle beside it. (A custom style squeezed it
/// into a narrow capsule.)
struct SettingsToolbarItem: ToolbarContent {
    @Binding var presentation: SettingsPresentation

    var body: some ToolbarContent {
        ToolbarItem {
            Button("Settings", systemImage: "gearshape") {
                presentation.toggle()
            }
        }
    }
}

/// One profile in the profile rail: its avatar (with the activity badge) over its
/// name, on a rounded fill when selected. Narrow, like a chat app's folder rail.
struct ProfileRailItem: View {
    static let width: CGFloat = 76

    let bot: Bot
    let activity: BotActivity
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                BotAvatar(name: bot.displayName, activity: activity, size: 40)
                Text(bot.displayName)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Hover.cornerRadius)
                        .fill(.tint.opacity(0.15))
                }
            }
            .contentShape(.rect(cornerRadius: Hover.cornerRadius))
        }
        .hoverButtonStyle(.rounded, padding: 0)
        .help(bot.displayName)
        .accessibilityLabel(bot.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Lists this profile's sessions")
    }
}

/// A server's name over its profiles in the profile rail, with several servers: a
/// status dot and the name, small enough for the rail.
struct RailServerHeader: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A server's section header in the sidebar, with several servers: its name and,
/// unless connected, its connection status.
struct ServerSectionHeader: View {
    let name: String
    let status: String
    let color: Color
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(name)
                .lineLimit(1)
            if !isConnected {
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The connection status, with an optional accessory on the same line. A fixed
/// height, so the footer is the same with or without it, on both platforms.
struct SidebarFooter<Accessory: View>: View {
    static var height: CGFloat { 28 }

    let status: String
    let color: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            accessory()
                .layoutPriority(1)
        }
        .frame(height: Self.height)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

struct BotRow: View {
    let bot: Bot
    let activity: BotActivity

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(name: bot.displayName, activity: activity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bot.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let lastActive = bot.lastActive {
                        Text(lastActive, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(activity == .waitingForYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch activity {
        case .waitingForYou: "Waiting for your answer"
        case .working: bot.preview.map { "Working… \($0)" } ?? "Working…"
        case .recent, .idle: bot.preview ?? (bot.hasChat ? "No messages yet" : "Say hello")
        }
    }
}

/// Initials on a colour picked from the name, with an activity badge.
struct BotAvatar: View {
    let name: String
    let activity: BotActivity
    var size: CGFloat = 32

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.375, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
            .overlay(alignment: .bottomTrailing) { badge }
    }

    @ViewBuilder private var badge: some View {
        switch activity {
        case .working:
            Image(systemName: "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)
                .accessibilityLabel("Working")
        case .waitingForYou:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white, .orange)
                .accessibilityLabel("Waiting for you")
        case .recent:
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.green)
                .accessibilityLabel("Active now")
        case .idle:
            EmptyView()
        }
    }

    private var initials: String {
        let words = name.split(separator: " ")
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    /// Stable across launches (`hashValue` is seeded per process).
    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let botName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.summary.title?.isEmpty == false ? entry.summary.title! : "Untitled chat")
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(botName)
                if let started = entry.summary.startedAt, started > 0 {
                    Text("·")
                    Text(Date(timeIntervalSince1970: started), format: .relative(presentation: .named))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

extension GatewayConnection.State {
    var statusText: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))…"
        case .failed(let message): message
        }
    }

    var statusColor: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .gray
        case .failed: .red
        }
    }
}
