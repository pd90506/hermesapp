import HermesKit
import HermesProtocol
import SwiftUI

// The sidebar's pieces, free of `AppModel` so `HermesMacTests` can host them as they are.

extension GatewayConnection.NavigationPage {
    var title: String {
        switch self {
        case .bots: "Bots"
        case .sessions: "Sessions"
        }
    }

    var subtitle: String {
        switch self {
        case .bots: "Each bot's ongoing chat"
        case .sessions: "Browse and start chats by profile"
        }
    }
}

/// The page name as a title-style menu button (ChatGPT's "ChatGPT ⌄ / Codex").
///
/// A native menu, so it opens from the keyboard and reads well in VoiceOver. With
/// `.plain`, SwiftUI draws the label itself; the system `.borderless`/automatic
/// styles make it an AppKit pop-up button instead. The hover fill sits outside the
/// menu (`hoverHighlight`), so it doesn't depend on the button style at all.
struct PageSwitcher: View {
    @Binding var page: GatewayConnection.NavigationPage

    var body: some View {
        Menu {
            ForEach(GatewayConnection.NavigationPage.allCases, id: \.self) { item in
                // A toggle shows the checkmark; the second Text is the menu item's subtitle.
                Toggle(isOn: Binding(get: { page == item }, set: { if $0 { page = item } })) {
                    Text(item.title)
                    Text(item.subtitle)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(page.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect(cornerRadius: Hover.cornerRadius))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
        .accessibilityLabel("Page")
        .accessibilityValue(page.title)
        .accessibilityHint("Switches between Bots and Sessions")
    }
}

/// The sidebar's pinned top, above the scrolling list (ChatGPT style): the page switcher
/// and, on Sessions, the New chat row. It never scrolls; rows scroll under it.
///
/// On Bots it is one row shorter, and the list starts that much higher. The switcher
/// and the toolbar stay put. Reserving the height on Bots would leave an empty band
/// above the bots for no action.
struct SidebarHeader: View {
    @Binding var page: GatewayConnection.NavigationPage
    /// The New chat row, or `nil` where there is none (Bots).
    var newChat: NewChatRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PageSwitcher(page: $page)
                .padding(.horizontal, Hover.rowInset)
            if let newChat {
                newChat
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }
}

/// The Sessions page's New chat, pinned under the switcher: a chat with the profile
/// picked in the footer. Not a List row, so it can never be selected, but drawn like
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

/// The Sessions page's profile, unlabeled: avatar, name and an up/down chevron.
struct ProfilePicker: View {
    let bots: [Bot]
    let selection: String?
    /// Main-actor: SwiftUI calls a `Binding`'s setter there.
    let select: @MainActor @Sendable (String) -> Void

    private var selected: Bot? { bots.first { $0.name == selection } }

    var body: some View {
        Menu {
            Picker("Profile", selection: Binding(get: { selection ?? "" }, set: select)) {
                ForEach(bots) { bot in
                    Text(bot.displayName).tag(bot.name)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                if let selected {
                    BotAvatar(name: selected.displayName, activity: .idle, size: 18)
                    Text(selected.displayName)
                        .lineLimit(1)
                } else {
                    Text("No profile")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(.rect(cornerRadius: Hover.cornerRadius))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .hoverHighlight()
        .disabled(bots.isEmpty)
        .accessibilityLabel("Profile")
        .accessibilityValue(selected?.displayName ?? "None")
        .accessibilityHint("Chooses whose sessions are listed")
    }
}

/// The connection status, with an optional accessory (the Sessions profile picker)
/// on the same line. A fixed height, so the footer is the same with or without it,
/// on both pages and both platforms.
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
