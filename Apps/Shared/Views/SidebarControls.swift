import HermesKit
import HermesProtocol
import ImageIO
import SwiftUI

// The sidebar's pieces, free of `AppModel` so `HermesMacTests` can host them as they are.

/// The session list's pinned top, above the scrolling list (ChatGPT and Slack style): the
/// selected profile's name (and, with several servers, its server), with the New chat
/// button at its trailing edge, centered on the name. It never scrolls; rows scroll under
/// it. On iPhone the profile's avatar leads it, as Slack's workspace icon.
struct SessionListHeader<Leading: View>: View {
    /// The profile's name.
    var title: String
    /// The profile's server, when there are several.
    var subtitle: String?
    /// New chat, or `nil` when no profile is selected.
    var newChat: NewChatButton?
    /// Before the title: on iPhone the profile's avatar.
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            leading
            ColumnTitle(title: title, subtitle: subtitle, style: .title3, weight: .semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let newChat {
                newChat
            }
        }
        // An avatar's button has its own margin, as New chat's at the other end.
        .padding(.leading, Leading.self == EmptyView.self ? Hover.rowContentInset : Hover.rowInset)
        .padding(.trailing, Hover.rowInset)
        .padding(.vertical, 4)
        .padding(.bottom, 6)
    }
}

extension SessionListHeader where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, newChat: NewChatButton? = nil) {
        self.init(title: title, subtitle: subtitle, newChat: newChat) { EmptyView() }
    }
}

/// The session list's title: the profile's name, and under it its server and status.
struct ColumnTitle: View {
    let title: String
    var subtitle: String?
    /// The text style of the title (the header's is `.title3`).
    var style: Font.TextStyle = .headline
    var weight: Font.Weight? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .uiFont(style, weight: weight)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// New chat: an icon-only button (the compose glyph) at the trailing edge of the list's
/// header, that starts a chat with the profile picked in the profile rail.
struct NewChatButton: View {
    var isEnabled: Bool
    /// Read by VoiceOver while the button is disabled.
    var disabledReason: String?
    var action: () -> Void

    var body: some View {
        Button("New chat", systemImage: "square.and.pencil", action: action)
            .labelStyle(.iconOnly)
            #if os(iOS)
            .uiFont(.title3)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            #else
            .uiFont(.title3)
            .hoverButtonStyle(.circle, padding: 6)
            #endif
            .disabled(!isEnabled)
            .help("New chat")
            .accessibilityHint(isEnabled ? "Starts a new chat" : disabledReason ?? "")
    }
}

/// One profile in the profile rail, as in Discord's server rail: on macOS only its
/// avatar (the name is the tooltip), a circle that turns into a rounded square when
/// selected or hovered, with a pill on the rail's leading edge, tall when selected and
/// short on hover. iOS has no pointer, so there the name sits under the avatar.
struct ProfileRailItem: View {
    // On the Mac narrower than it was (64 pt, 40 pt avatars): the user found the rail too
    // wide beside the session list (2026-10-19).
    #if os(macOS)
    static let width: CGFloat = 54
    static let avatarSize: CGFloat = 36
    #else
    static let width: CGFloat = 76
    static let avatarSize: CGFloat = 40
    #endif
    /// Space above and below the avatar.
    static let verticalPadding: CGFloat = 4

    let bot: Bot
    let activity: BotActivity
    let isSelected: Bool
    /// The profile's avatar image, when it has one.
    var image: CGImage? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                BotAvatar(name: bot.displayName, activity: activity, size: Self.avatarSize, image: image,
                          color: bot.avatarColor.map(Color.init(rgb:)), squared: isSelected || isHovered)
                #if os(iOS)
                Text(bot.displayName)
                    .uiFont(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                #endif
            }
            .padding(.vertical, Self.verticalPadding)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            // Level with the avatar's middle, against the rail's edge.
            UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 2, topTrailing: 2))
                .fill(.tint)
                .frame(width: 4, height: pillHeight)
                .offset(y: Self.verticalPadding + (Self.avatarSize - pillHeight) / 2)
                .opacity(pillHeight > 0 ? 1 : 0)
                .accessibilityHidden(true)
        }
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .animation(.snappy(duration: 0.2), value: isSelected)
        .animation(.snappy(duration: 0.15), value: isHovered)
        .help(bot.displayName)
        .accessibilityLabel(bot.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Lists this profile's sessions")
    }

    private var pillHeight: CGFloat {
        isSelected ? 28 : isHovered ? 10 : 0
    }
}

/// A server's mark over its profiles in the profile rail, with several servers: a
/// computer for this Mac, a server for the others, with the status dot on its corner.
/// The name and status are the tooltip.
struct RailServerHeader: View {
    let name: String
    let color: Color
    var isLocal = false
    /// What the dot means, for VoiceOver and UI tests ("Connected").
    var status = ""

    var body: some View {
        Image(systemName: isLocal ? "laptopcomputer" : "server.rack")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 18)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: 1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityValue(status)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Bot Chat's row: like a session row (`HistoryRow`), with no avatar (the profile
/// rail beside it shows the bot's, with its activity badge).
struct BotRow: View {
    let bot: Bot
    let activity: BotActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(bot.displayName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let lastActive = bot.lastActive {
                    Text(lastActive, format: .relative(presentation: .named))
                        .uiFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(subtitle)
                .uiFont(.caption)
                .foregroundStyle(activity == .waitingForYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
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

/// A sidebar section's title ("Bot Chat", "Pinned", "Sessions"): one font and colour
/// for all of them, so the pinned Bot Chat's header reads as a peer of the list's.
struct SidebarSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .uiFont(.subheadline, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

/// The Bot Chat row pinned above the session list: a `BotRow` under a "Bot Chat"
/// header (in the Sessions header's style), set in like the list's rows, with their
/// hover and selected fill (`SurfaceColors.selection`; the List's selection can't reach a row
/// outside it).
/// A divider under it, always shown, sets it off from the sessions.
struct PinnedBotChat: View {
    let bot: Bot
    let activity: BotActivity
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionTitle(Bot.chatTitle)
                .padding(.horizontal, Hover.rowContentInset)
                .accessibilityHidden(true)
            Button(action: open) {
                BotRow(bot: bot, activity: activity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Style(isSelected: isSelected))
            .padding(.horizontal, Hover.rowInset)
            .accessibilityIdentifier("pinnedBotChat")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Divider()
                .padding(.horizontal, Hover.rowContentInset)
                .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    private struct Style: ButtonStyle {
        var isSelected: Bool
        @Environment(\.surfaces) private var surfaces

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: Hover.cornerRadius)
            configuration.label
                .padding(.horizontal, Hover.rowContentInset - Hover.rowInset)
                .padding(.vertical, 4)
                .background { shape.fill(surfaces.selection).opacity(isSelected ? 1 : 0) }
                .contentShape(shape)
                .hoverHighlight(in: shape, isEnabled: !isSelected)
        }
    }
}

/// The profile's avatar image, or initials on its colour (Desktop's pick, else one
/// from the name), with an activity badge.
struct BotAvatar: View {
    let name: String
    let activity: BotActivity
    var size: CGFloat = 32
    var image: CGImage? = nil
    var color: Color? = nil
    /// A rounded square instead of a circle.
    var squared = false

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: squared ? size * 0.3 : size / 2, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.375, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((color ?? fallbackColor).gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
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
    private var fallbackColor: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }
}

extension Color {
    /// A colour from 0xRRGGBB.
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

/// Avatar images: decoded once per image and kept small, and a picked file turned into
/// what `profiles.set_asset` takes.
@MainActor
enum AvatarImages {
    /// The side of an uploaded avatar, as Desktop's picker makes it (`normalizeAvatarImage`,
    /// `plugins/hermes-bots/avatar-image.ts:18`).
    nonisolated static let uploadEdge = 256
    private static var decoded: [Data: CGImage] = [:]

    /// The image in `data`, at most 128 px a side (the rail draws it at 40 pt).
    static func image(_ data: Data?) -> CGImage? {
        guard let data else { return nil }
        if let cached = decoded[data] { return cached }
        guard let image = thumbnail(of: data, maxPixels: 128) else { return nil }
        if decoded.count > 64 { decoded.removeAll() }
        decoded[data] = image
        return image
    }

    /// The image in `data`, cropped to its centre square and scaled to `uploadEdge`, as a PNG.
    nonisolated static func uploadPNG(from data: Data) -> Data? {
        guard let image = thumbnail(of: data, maxPixels: uploadEdge * 4) else { return nil }
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop),
            let context = CGContext(data: nil, width: uploadEdge, height: uploadEdge, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: uploadEdge, height: uploadEdge))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString,
                                                                  1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The image in `data`, upright, at most `maxPixels` a side.
    nonisolated private static func thumbnail(of data: Data, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A session of the selected profile: its title and when it started (the profile is
/// the list's, so it isn't repeated on every row), and its actions behind a "…" button
/// at the trailing edge (the same as its context menu).
struct HistoryRow<Actions: View>: View {
    let entry: HistoryEntry
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary.title?.isEmpty == false ? entry.summary.title! : "Untitled chat")
                    .lineLimit(1)
                if let started = entry.summary.startedAt, started > 0 {
                    Text(Date(timeIntervalSince1970: started), format: .relative(presentation: .named))
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .uiFont(.body, weight: .semibold)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            // Plain, with the style on the menu (as the composer's menus): a borderless
            // menu button drew its glyph black whatever the appearance.
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("More")
            .accessibilityLabel("More actions")
        }
        .padding(.vertical, 2)
        .contextMenu { actions() }
    }
}

/// A session row's actions, in its context menu and its "…" menu.
struct SessionActions: View {
    let isPinned: Bool
    var canChange = true
    let pin: () -> Void
    let rename: () -> Void
    let fork: () -> Void
    let archive: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin", action: pin)
        Button("Rename…", systemImage: "pencil", action: rename)
            .disabled(!canChange)
        Button("Fork", systemImage: "arrow.triangle.branch", action: fork)
            .disabled(!canChange)
        Button("Archive", systemImage: "archivebox", action: archive)
            .disabled(!canChange)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
            .disabled(!canChange)
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
