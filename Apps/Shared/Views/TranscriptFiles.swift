import Foundation
import HermesKit
import QuickLook
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Files on the gateway that this device has downloaded, to preview or save.
///
/// - A file is downloaded once per server, profile and path
///   (`GatewayConnection.downloadFile`, `GET /api/fs/download`) into the app's caches
///   folder, under its own name, so Quick Look and Save show the right name and type.
/// - Concurrent requests for one file share a download. A failed one is not cached.
/// - The caches folder is the system's to purge; a missing copy is downloaded again.
@MainActor
final class FileDownloads {
    private let folder: URL
    private var inFlight: [String: Task<URL, any Error>] = [:]

    init(serverID: UUID) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("Delivered Files", isDirectory: true)
            .appendingPathComponent(serverID.uuidString, isDirectory: true)
    }

    /// The local copy of `path`, downloaded if needed. `sessionKey`: the stored
    /// session a relative path belongs to.
    func localCopy(of path: String, profile: String?, sessionKey: String?,
                   connection: GatewayConnection) async throws -> URL {
        let key = "\(profile ?? ""):\(path)"
        let destination = folder
            .appendingPathComponent(Self.digest(key), isDirectory: true)
            .appendingPathComponent(AttachmentRefs.displayName(path))
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let running = inFlight[key] { return try await running.value }
        // Relative paths only: an absolute one needs no session, and a chat Hermes
        // has not stored yet would answer 404 for it.
        let session = path.hasPrefix("/") || path.hasPrefix("~") ? nil : sessionKey
        let task = Task<URL, any Error> {
            let temporary = try await connection.downloadFile(path: path, profile: profile, sessionID: session)
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: temporary, to: destination)
            return destination
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// A stable folder name for a key (FNV-1a; not security-relevant).
    private static func digest(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// What a file card needs to fetch its file.
struct GatewayFileContext {
    var profile: String?
    /// The chat's stored session key, for relative paths.
    var sessionKey: String?
    var connection: GatewayConnection
    var downloads: FileDownloads
}

/// Download state and actions shared by file and image cards: preview with Quick
/// Look, save with the system's save panel (macOS) or the Files picker (iOS), share.
@MainActor
@Observable
final class GatewayFileActions {
    let path: String
    let context: GatewayFileContext
    private(set) var isDownloading = false
    var error: String?
    /// Set to preview: `quickLookPreview` shows it.
    var previewURL: URL?
    /// iOS: the copy the Files picker moves where the user chooses.
    var exportURL: URL?
    var isExporting = false
    /// Downloaded already: shown in the share menu.
    private(set) var localURL: URL?

    init(path: String, context: GatewayFileContext) {
        self.path = path
        self.context = context
    }

    var name: String { AttachmentRefs.displayName(path) }

    private func download() async -> URL? {
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) { return localURL }
        isDownloading = true
        error = nil
        defer { isDownloading = false }
        do {
            let url = try await context.downloads.localCopy(of: path, profile: context.profile,
                                                            sessionKey: context.sessionKey,
                                                            connection: context.connection)
            localURL = url
            return url
        } catch {
            self.error = "Couldn't download \(name): \(GatewayConnection.describe(error))"
            return nil
        }
    }

    func preview() async {
        guard let url = await download() else { return }
        previewURL = url
    }

    func save() async {
        guard let url = await download() else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let target = panel.url else { return }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: target.path) { _ = try manager.replaceItemAt(target, withItemAt: copy(url)) }
            else { try manager.copyItem(at: url, to: target) }
        } catch {
            self.error = "Couldn't save \(name): \(error.localizedDescription)"
        }
        #else
        do {
            exportURL = try copy(url)
            isExporting = true
        } catch {
            self.error = "Couldn't save \(name): \(error.localizedDescription)"
        }
        #endif
    }

    #if os(macOS)
    func openWithDefaultApp() async {
        guard let url = await download() else { return }
        NSWorkspace.shared.open(url)
    }
    #endif

    /// A copy the save can consume, so the cached file stays.
    private func copy(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

extension View {
    /// Quick Look, the iOS Files export and errors for a file card's actions.
    func gatewayFilePresentation(_ actions: GatewayFileActions) -> some View {
        @Bindable var actions = actions
        return self
            .quickLookPreview($actions.previewURL)
            #if os(iOS)
            .fileMover(isPresented: $actions.isExporting, file: actions.exportURL) { result in
                if case .failure(let error) = result { actions.error = error.localizedDescription }
            }
            #endif
    }
}

/// A file in a message: its icon and name; click (tap) to preview it, with Save
/// and Share in its menu. Hermes sends one with a `MEDIA:` tag (Desktop's file card,
/// `apps/desktop/src/components/chat/preview-attachment.tsx`); a user message lists
/// the files sent with it.
struct FileChipView: View {
    let name: String
    @State private var actions: GatewayFileActions

    init(path: String, name: String? = nil, context: GatewayFileContext) {
        self.name = name ?? AttachmentRefs.displayName(path)
        _actions = State(initialValue: GatewayFileActions(path: path, context: context))
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Task { await actions.preview() }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if actions.isDownloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: FileKind(filename: name).systemImage)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .uiFont(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let error = actions.error {
                            Text(error)
                                .uiFont(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Preview \(name)")
            .accessibilityLabel("File \(name)")
            .accessibilityHint("Opens a preview")

            Menu {
                fileMenu
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .accessibilityLabel("More actions for \(name)")
        }
        .frame(maxWidth: 320, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1) }
        .contextMenu { fileMenu }
        .gatewayFilePresentation(actions)
    }

    @ViewBuilder private var fileMenu: some View {
        Button("Preview", systemImage: "eye") { Task { await actions.preview() } }
        #if os(macOS)
        Button("Save…", systemImage: "square.and.arrow.down") { Task { await actions.save() } }
        Button("Open", systemImage: "arrow.up.forward.app") { Task { await actions.openWithDefaultApp() } }
        #else
        Button("Save to Files", systemImage: "folder") { Task { await actions.save() } }
        #endif
        if let url = actions.localURL {
            ShareLink(item: url)
        }
    }
}

/// What a reply delivers with `MEDIA:` tags, under its text: images as thumbnails
/// (click to preview), every other file as a `FileChipView`.
struct DeliveredFilesView: View {
    let files: [DeliveredFile]
    let context: GatewayFileContext
    let thumbnails: ThumbnailStore

    var body: some View {
        let images = files.filter(\.isImage)
        let others = files.filter { !$0.isImage }
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                LeadingFlowLayout {
                    ForEach(Array(images.enumerated()), id: \.element.id) { position, file in
                        DeliveredImageCard(file: file, position: position, context: context, thumbnails: thumbnails)
                    }
                }
            }
            ForEach(others) { file in
                FileChipView(path: file.path, context: context)
            }
        }
    }
}

/// A delivered image: its thumbnail (`TranscriptImageCard`); click to preview it full size.
private struct DeliveredImageCard: View {
    let file: DeliveredFile
    let position: Int
    let thumbnails: ThumbnailStore
    let context: GatewayFileContext
    @State private var actions: GatewayFileActions

    init(file: DeliveredFile, position: Int, context: GatewayFileContext, thumbnails: ThumbnailStore) {
        self.file = file
        self.position = position
        self.context = context
        self.thumbnails = thumbnails
        _actions = State(initialValue: GatewayFileActions(path: file.path, context: context))
    }

    var body: some View {
        Button {
            Task { await actions.preview() }
        } label: {
            TranscriptImageCard(image: TranscriptImage(path: file.path, position: position), profile: context.profile,
                                store: thumbnails, connection: context.connection)
                .overlay(alignment: .bottomTrailing) {
                    if actions.isDownloading {
                        ProgressView().controlSize(.small).padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(actions.error ?? "Preview \(file.name)")
        .accessibilityHint("Opens a preview")
        .contextMenu {
            Button("Preview", systemImage: "eye") { Task { await actions.preview() } }
            #if os(macOS)
            Button("Save…", systemImage: "square.and.arrow.down") { Task { await actions.save() } }
            #else
            Button("Save to Files", systemImage: "folder") { Task { await actions.save() } }
            #endif
            if let url = actions.localURL { ShareLink(item: url) }
        }
        .gatewayFilePresentation(actions)
    }
}

/// Lays its children out in rows, leading-aligned, wrapping at the proposed width.
struct LeadingFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        TrailingFlowLayout(spacing: spacing).sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
