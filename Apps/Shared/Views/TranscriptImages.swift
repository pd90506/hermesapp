import CoreGraphics
import Foundation
import HermesKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// Decoded thumbnails of images in the transcript, bounded in memory.
///
/// - An image sent from here is cached under its attachment id as soon as it is
///   attached (`storeLocal`), and under its gateway path the first time its bubble
///   shows it: the stored row that replaces the bubble names the same path, so it
///   shows the same thumbnail without a download or a visible swap.
/// - A stored `@image:` path is read once through `GatewayConnection.imageData`
///   (`/api/media`, or `/api/fs/read-data-url` for another profile's upload), decoded
///   to at most `maxPixels` off the main thread, and cached.
/// - A read that failed (403, 404, 413, offline) is not retried for `retryAfter`; the
///   card shows a placeholder with the file name meanwhile.
@MainActor
final class ThumbnailStore {
    /// Longest side of a decoded thumbnail: a 160 pt card at 3x.
    nonisolated static let maxPixels = ImageLoader.thumbnailPixels
    static let retryAfter: TimeInterval = 60

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    /// A few downloads and decodes at a time: each briefly holds a base64 string and its bytes.
    private let limiter = AsyncLimiter(limit: 3)
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var failures: [String: Date] = [:]

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    private static func localKey(_ id: UUID) -> String { "local:\(id.uuidString)" }
    private static func pathKey(_ path: String, profile: String?) -> String { "path:\(profile ?? ""):\(path)" }

    private func store(_ image: CGImage, key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    private func get(_ key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }

    /// The thumbnail of an image just attached in the composer.
    func storeLocal(_ image: CGImage, for id: UUID) {
        store(image, key: Self.localKey(id))
    }

    /// The thumbnail of an attachment, if still in memory.
    func local(_ id: UUID) -> CGImage? {
        get(Self.localKey(id))
    }

    /// What is in memory for `image`, without loading anything.
    func cached(_ image: TranscriptImage, profile: String?) -> CGImage? {
        let pathKey = image.path.map { Self.pathKey($0, profile: profile) }
        if let pathKey, let hit = get(pathKey) { return hit }
        guard let id = image.localID, let local = get(Self.localKey(id)) else { return nil }
        if let pathKey { store(local, key: pathKey) }  // the stored row will ask by path
        return local
    }

    /// The thumbnail of a stored image, read from the gateway once; `nil` when it
    /// cannot be read.
    func load(_ image: TranscriptImage, profile: String?, connection: GatewayConnection) async -> CGImage? {
        if let hit = cached(image, profile: profile) { return hit }
        guard let path = image.path else { return nil }
        let key = Self.pathKey(path, profile: profile)
        if let failed = failures[key], Date().timeIntervalSince(failed) < Self.retryAfter { return nil }
        if let running = inFlight[key] { return await running.value }
        let limiter = limiter
        let task = Task<CGImage?, Never> {
            await limiter.run {
                guard let data = try? await connection.imageData(path: path, profile: profile) else { return nil }
                if let image = await Self.decode(data) { return image }
                // ImageIO cannot draw SVG; Quick Look can.
                return Self.isVector(path) ? await Self.quickLookThumbnail(data, fileExtension: "svg") : nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            store(result, key: key)
            failures[key] = nil
        } else {
            failures[key] = Date()
        }
        return result
    }

    nonisolated static func isVector(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "svg"
    }

    /// A thumbnail drawn by Quick Look, for formats ImageIO cannot decode (SVG). It
    /// reads a file, so the bytes are written to a temporary one first.
    nonisolated static func quickLookThumbnail(_ data: Data, fileExtension: String) async -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let side = CGFloat(maxPixels) / 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// A downsampled decode, refused when the image is larger than
    /// `TranscriptImage.maxDecodePixels` (its dimensions are read from the header first).
    @concurrent
    nonisolated static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard TranscriptImage.mayDecode(width: properties[kCGImagePropertyPixelWidth] as? Int,
                                        height: properties[kCGImagePropertyPixelHeight] as? Int)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}

/// An image in a user message: its thumbnail in a fixed-size card, so the live
/// bubble and the stored row that replaces it look the same and nothing jumps.
/// A placeholder with the file name when the image cannot be read.
struct TranscriptImageCard: View {
    let image: TranscriptImage
    let profile: String?
    let store: ThumbnailStore
    let connection: GatewayConnection
    @State private var thumbnail: CGImage?
    @State private var failed = false

    static let size = CGSize(width: 160, height: 120)

    init(image: TranscriptImage, profile: String?, store: ThumbnailStore, connection: GatewayConnection) {
        self.image = image
        self.profile = profile
        self.store = store
        self.connection = connection
        // Synchronously from memory: a cached image shows in the very first frame.
        _thumbnail = State(initialValue: store.cached(image, profile: profile))
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.title3)
                    Text(image.name)
                        .font(.caption2)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(8)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.quaternary.opacity(0.5))
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1) }
        .animation(.easeOut(duration: 0.15), value: thumbnail != nil)
        .help(image.name)
        .accessibilityElement()
        .accessibilityLabel("Image \(image.name)")
        .task(id: image.id) {
            guard thumbnail == nil else { return }
            thumbnail = await store.load(image, profile: profile, connection: connection)
            failed = thumbnail == nil
        }
    }
}

/// Lays its children out in rows, trailing-aligned, wrapping at the proposed width.
struct TrailingFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
