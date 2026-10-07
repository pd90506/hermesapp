import HermesKit
import HermesProtocol
import SwiftUI

/// What the sidebar can select.
enum SidebarItem: Hashable {
    /// A bot, by profile name. Selecting it opens its one Bot Chat.
    case bot(String)
    /// A Sessions row, by `HistoryEntry.id`.
    case history(String)
}

/// Native page switch, bot roster and profile-scoped session browser.
struct BotSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        @Bindable var connection = model.connection
        List(selection: $selection) {
            Section {
                Picker("Page", selection: $connection.navigationPage) {
                    Text("Bots").tag(GatewayConnection.NavigationPage.bots)
                    Text("Sessions").tag(GatewayConnection.NavigationPage.sessions)
                }
                .pickerStyle(.segmented)
                if connection.navigationPage == .sessions {
                    Picker("Profile", selection: Binding(
                        get: { connection.listProfile ?? "" },
                        set: { connection.selectListProfile($0) })) {
                        ForEach(connection.bots) { bot in
                            Text(bot.displayName).tag(bot.name)
                        }
                    }
                    .disabled(connection.bots.isEmpty)
                }
            }

            if let error = model.actionError {
                Section {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { model.actionError = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }
            if !model.connection.otherSessionRequests.isEmpty {
                Section {
                    Label("\(model.connection.otherSessionRequests.count) chat(s) waiting for you",
                          systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
            }
            if connection.navigationPage == .bots {
                Section("Bots") {
                    ForEach(model.connection.bots) { bot in
                        BotRow(bot: bot, activity: model.connection.activity(for: bot))
                            .tag(SidebarItem.bot(bot.name))
                            .contextMenu {
                                Button("New Side Chat", systemImage: "plus.bubble") { startSideChat(with: bot) }
                            }
                    }
                }
            } else {
                Section("Sessions") {
                    // Only before the first rows: background refreshes keep the list still.
                    if connection.sessionListLoading && connection.history.isEmpty {
                        ProgressView("Loading sessions…")
                    }
                    if let error = connection.sessionListError {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { Task { await connection.refreshSessionList() } }
                    }
                    if connection.bots.isEmpty {
                        Text(model.isConnected ? "No profiles available" : "Connect to browse sessions")
                            .foregroundStyle(.secondary)
                    } else if connection.history.isEmpty && !connection.sessionListLoading
                                && connection.sessionListError == nil {
                        Text("No sessions yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(connection.history) { entry in
                        HistoryRow(entry: entry, botName: displayName(of: entry.profile))
                            .tag(SidebarItem.history(entry.id))
                    }
                }
            }
        }
        .navigationTitle(connection.navigationPage == .bots ? "Bots" : "Sessions")
        .refreshable { await model.refreshLists() }
        .safeAreaInset(edge: .bottom) {
            ConnectionStatusBar()
        }
        .toolbar {
            ToolbarItem {
                if connection.navigationPage == .sessions {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        if let bot = connection.bots.first(where: { $0.name == connection.listProfile }) {
                            startSideChat(with: bot)
                        }
                    }
                    .disabled(!model.isConnected || connection.listProfile == nil)
                } else {
                    Menu("New Side Chat", systemImage: "square.and.pencil") {
                        ForEach(model.connection.bots) { bot in
                            Button(bot.displayName) { startSideChat(with: bot) }
                        }
                    }
                    .disabled(!model.isConnected || model.connection.bots.isEmpty)
                }
            }
            ToolbarItem {
                Button("Connection", systemImage: "gearshape") {
                    model.isShowingSettings = true
                }
            }
        }
        .task(id: "\(connection.navigationPage.rawValue):\(connection.listProfile ?? ""):\(model.isConnected)") {
            await connection.refreshSessionListIfVisible()
        }
        .task(id: model.isConnected) {
            // Keeps previews and activity dots current (Desktop re-reads the roster every 5 s).
            guard model.isConnected else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                model.connection.refreshListsInBackground()
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        #endif
    }

    private func displayName(of profile: String) -> String {
        model.connection.bots.first { $0.name == profile }?.displayName ?? profile
    }

    private func startSideChat(with bot: Bot) {
        selection = nil
        Task {
            do {
                try await model.connection.newSideChat(profile: bot.name)
            } catch {
                model.actionError = GatewayConnection.describe(error)
            }
        }
    }
}

private struct BotRow: View {
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
private struct BotAvatar: View {
    let name: String
    let activity: BotActivity

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    var body: some View {
        Text(initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
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

private struct HistoryRow: View {
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

private struct ConnectionStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // The list scrolls under this inset; without a bar behind it, rows
        // showed through the status text.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch model.connection.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))…"
        case .failed(let message): message
        }
    }

    private var color: Color {
        switch model.connection.state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .gray
        case .failed: .red
        }
    }
}
