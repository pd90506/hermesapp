#if os(iOS)
import HermesKit
import HermesProtocol
import ImageIO
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// What a reply embeds on iOS (`ReplyParts`, `docs/protocol.md` §10.11): web images,
/// drawn natively, and `::preview` widgets, live in a `WKWebView` the way the Electron
/// app and Hermes Desktop run them in a sandboxed frame. The rest of the chat stays
/// native; only a widget is a web view (the user, 2026-11-21: "在 SwiftUI 里放一个
/// WKWebView").
struct ReplyEmbedView: View {
    let segment: ReplyParts.Segment
    let isStreaming: Bool
    let session: ChatSession
    let profile: String?
    let connection: GatewayConnection
    /// A file that isn't a page shows as a delivered file's card.
    let fileCard: (String) -> AnyView

    var body: some View {
        switch segment {
        case .images(let images):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(images) { WebImageView(image: $0, connection: connection) }
            }
        case .directive(let directive):
            DirectiveEmbedView(directive: directive, isStreaming: isStreaming, session: session, profile: profile,
                               connection: connection, fileCard: fileCard)
        case .markdown, .files:
            EmptyView()
        }
    }
}

// MARK: - Web images

/// Web images in replies, fetched by the app (no cookies, as a browser would load them
/// for a page that sends none) or else through the gateway's proxy, as Desktop retries one
/// it could not load. Decoded at most `maxPixels` a side, kept in memory, and written to
/// the caches folder so Quick Look can show one full size. A failure is not remembered:
/// the next time the reply shows, it tries again.
@MainActor
final class WebImageStore {
    static let shared = WebImageStore()

    nonisolated static let maxBytes = 20 * 1024 * 1024
    nonisolated static let maxPixels = 2048
    /// As the Electron app draws them (`--web-image-max-width`, `--web-image-max-height`).
    static let maxSize = CGSize(width: 640, height: 420)

    struct Loaded: Sendable {
        let image: CGImage
        /// The image's own size in pixels, drawn as points like a browser's CSS pixels.
        let pixelSize: CGSize
        /// The bytes on disk, for Quick Look.
        let file: URL
    }

    private final class Box {
        let value: Loaded
        init(_ value: Loaded) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()
    private var inFlight: [URL: Task<Loaded?, Never>] = [:]
    private let limiter = AsyncLimiter(limit: 3)
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Web Images", isDirectory: true)

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func cached(_ url: URL) -> Loaded? { cache.object(forKey: url.absoluteString as NSString)?.value }

    func load(_ url: URL, connection: GatewayConnection) async -> Loaded? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let (session, folder, limiter) = (session, folder, limiter)
        let task = Task<Loaded?, Never> {
            await limiter.run {
                var data = await Self.fetch(url, session: session)
                if data == nil { data = try? await connection.proxiedImage(url) }
                guard let data else { return nil }
                return await Self.prepare(data, url: url, folder: folder)
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            cache.setObject(Box(result), forKey: url.absoluteString as NSString,
                            cost: result.image.bytesPerRow * result.image.height)
        }
        return result
    }

    /// The image's bytes: a 2xx answer typed `image/…`, at most `maxBytes`.
    @concurrent
    nonisolated static func fetch(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            (http.mimeType ?? "").lowercased().hasPrefix("image/"),
            http.expectedContentLength <= Int64(maxBytes)
        else { return nil }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : data
    }

    /// Decoded (refused when larger than `TranscriptImage.maxDecodePixels`) and written
    /// to the caches folder under a name of its own, with its type's extension.
    @concurrent
    nonisolated static func prepare(_ data: Data, url: URL, folder: URL) async -> Loaded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        guard TranscriptImage.mayDecode(width: width, height: height),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        else { return nil }
        // The thumbnail is upright (`WithTransform`): its sides, scaled back up, are the image's.
        let scale = max(1, Double(max(width ?? image.width, height ?? image.height)) / Double(max(image.width, image.height)))
        let pixelSize = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let file = folder.appendingPathComponent(digest(url.absoluteString))
            .appendingPathExtension(type?.preferredFilenameExtension ?? "img")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return Loaded(image: image, pixelSize: pixelSize, file: file)
    }

    /// A stable file name for a URL (FNV-1a; not security-relevant).
    nonisolated private static func digest(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// A web image in a reply, as Desktop draws `![alt](url)`: at its own size, never larger
/// than the column (nor 640 × 420); a tap shows it full size in Quick Look. Until it
/// loads, and when it can't, its name.
struct WebImageView: View {
    let image: WebImage
    let connection: GatewayConnection
    @State private var loaded: WebImageStore.Loaded?
    @State private var failed = false
    @State private var previewURL: URL?
    @Environment(\.openURL) private var openURL

    init(image: WebImage, connection: GatewayConnection) {
        self.image = image
        self.connection = connection
        // From memory: a loaded image shows in the very first frame.
        _loaded = State(initialValue: WebImageStore.shared.cached(image.url))
    }

    var body: some View {
        Group {
            if let loaded {
                let size = Self.shownSize(loaded.pixelSize)
                Button {
                    previewURL = loaded.file
                } label: {
                    Image(decorative: loaded.image, scale: 1)
                        .resizable()
                        .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
                        .frame(maxWidth: size.width, alignment: .leading)
                        .clipShape(.rect(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.05), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(image.alt.isEmpty ? "Image \(image.name)" : image.alt)
                .accessibilityHint("Shows it full size")
                .quickLookPreview($previewURL)
            } else if failed {
                HStack(spacing: 4) {
                    Text("Couldn’t load \(image.name).")
                    Button("Open in Browser") { openURL(image.url) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Loading \(image.name)…")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task(id: image.url) {
            guard loaded == nil else { return }
            failed = false
            loaded = await WebImageStore.shared.load(image.url, connection: connection)
            failed = loaded == nil
        }
    }

    /// Its own size, scaled down to fit 640 × 420.
    static func shownSize(_ pixels: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return WebImageStore.maxSize }
        let scale = min(1, WebImageStore.maxSize.width / pixels.width, WebImageStore.maxSize.height / pixels.height)
        return CGSize(width: pixels.width * scale, height: pixels.height * scale)
    }
}

// MARK: - Widgets

/// A directive a reply holds: `preview` draws its page in place (or a web address as a
/// link, another file as its card); anything else draws nothing.
struct DirectiveEmbedView: View {
    let directive: TranscriptDirective
    let isStreaming: Bool
    let session: ChatSession
    let profile: String?
    let connection: GatewayConnection
    let fileCard: (String) -> AnyView
    @Environment(\.openURL) private var openURL

    var body: some View {
        if directive.name == "preview", let target = PreviewTarget(file: directive.attrs["file"]) {
            switch target {
            case .url(let url):
                Button(url.absoluteString) { openURL(url) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.leading)
            case .file(let path):
                fileCard(path)
            case .html(let path):
                PreviewWidgetView(path: path, initialHeight: WidgetFrame.initialHeight(directive.attrs["height"]),
                                  isStreaming: isStreaming, session: session, profile: profile,
                                  connection: connection, fileCard: fileCard)
            }
        }
    }
}

/// An HTML page the agent wrote, live in the reply (Desktop's `InlineHtmlFrame`). The page
/// is read once the reply has finished (mid-stream it may be half-written) and again after
/// each later turn, so a widget the agent updates shows the new page. It wears the app's
/// colours (`WidgetFrame.Theme`), its height follows its content, and its `hermes.send`
/// prompts go to this chat as hidden turns. A binary, cut or unreadable file shows as
/// the file's card.
struct PreviewWidgetView: View {
    let path: String
    let initialHeight: Int?
    let isStreaming: Bool
    let session: ChatSession
    let profile: String?
    let connection: GatewayConnection
    let fileCard: (String) -> AnyView
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var html: String?
    @State private var failed = false
    @State private var measured: Int?
    /// Turns that finished since this showed: each one reads the page again.
    @State private var turns = 0
    /// Only messages carrying this mount's token count.
    @State private var token = UUID().uuidString
    @State private var lastIntentAt: Double = 0

    private struct ReadKey: Hashable {
        var path: String
        var isStreaming: Bool
        var turns: Int
    }

    private var height: Int { measured ?? initialHeight ?? WidgetFrame.defaultHeight }

    var body: some View {
        Group {
            if failed, html == nil {
                fileCard(path)
            } else {
                ZStack {
                    if let html {
                        WidgetWebView(page: page(html), onMessage: handle, openExternal: { openURL($0) })
                            .accessibilityLabel(path)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.5))
                            .accessibilityLabel("Loading \(path)")
                    }
                }
                .frame(maxWidth: CGFloat(WidgetFrame.maxWidth))
                .frame(height: CGFloat(height))
                .animation(.snappy(duration: 0.2), value: height)
            }
        }
        .onChange(of: session.transcript.isRunning) { wasRunning, isRunning in
            if wasRunning, !isRunning { turns += 1 }
        }
        .task(id: ReadKey(path: path, isStreaming: isStreaming, turns: turns)) {
            guard !isStreaming else { return }
            do {
                let file = try await connection.readText(path: path, profile: profile,
                                                         sessionKey: session.storedSessionID)
                guard !Task.isCancelled else { return }
                if file.binary || file.truncated || file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failed = true
                } else if html != file.text {
                    html = file.text
                }
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private func page(_ html: String) -> String {
        let isDark = colorScheme == .dark
        return WidgetFrame.hostPage(document: WidgetFrame.document(html, token: token, theme: theme(isDark: isDark)),
                                    title: path, isDark: isDark)
    }

    /// The app's colours, resolved for light or dark, under the names Hermes teaches
    /// the model; the system font.
    private func theme(isDark: Bool) -> WidgetFrame.Theme {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        func css(_ color: UIColor) -> String {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            let opacity = (Double(min(max(alpha, 0), 1)) * 1000).rounded() / 1000
            return "rgb(\(channel(red)) \(channel(green)) \(channel(blue)) / \(opacity))"
        }
        let accent = model.markdownColors.preset.nativeAccent ?? .tintColor
        return WidgetFrame.Theme(vars: [
            "--foreground": css(.label),
            "--muted-foreground": css(.tertiaryLabel),
            "--accent": css(accent),
            "--border": css(.separator),
            "--card": css(.secondarySystemBackground),
        ], font: "-apple-system, system-ui, sans-serif", isDark: isDark)
    }

    /// A message the page posted: a size report or a prompt.
    private func handle(_ data: JSONValue, reply: @escaping @MainActor (JSONValue) -> Void) {
        let now = Date().timeIntervalSince1970 * 1000
        if let decision = WidgetFrame.evaluateIntent(data, token: token, now: now, lastAcceptedAt: lastIntentAt) {
            let token = token
            let answer: @MainActor (WidgetFrame.IntentAck) -> Void = { ack in
                if let id = decision.id { reply(WidgetFrame.intentAck(token: token, id: id, ack: ack)) }
            }
            switch decision {
            case .reject(_, let ack):
                answer(ack)
            case .accept(_, let prompt):
                lastIntentAt = now
                let session = session
                Task { answer(await session.sendHidden(prompt) ? .ok : .init(error: .undelivered)) }
            }
            return
        }
        guard let reported = WidgetFrame.reportedHeight(data, token: token) else { return }
        if abs(reported - height) > WidgetFrame.resizeTolerance { measured = reported }
    }
}

/// The web view a widget runs in: the host page (`WidgetFrame.hostPage`) holding the
/// agent's page in a `sandbox="allow-scripts"` frame, so it runs with an opaque origin,
/// in a store of its own that keeps nothing (`nonPersistent`). Only the host itself may
/// post to the app; the frame's own posts to the handler are dropped. The web view never
/// navigates away: a link the page follows opens in the browser. It does not scroll; its
/// height is the widget's.
private struct WidgetWebView: UIViewRepresentable {
    let page: String
    let onMessage: @MainActor (JSONValue, @escaping @MainActor (JSONValue) -> Void) -> Void
    let openExternal: @MainActor (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(MessageRelay(context.coordinator), name: WidgetFrame.hostHandler)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.webView = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onMessage = onMessage
        coordinator.openExternal = openExternal
        if coordinator.page != page {
            coordinator.page = page
            view.loadHTMLString(page, baseURL: nil)
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: WidgetFrame.hostHandler)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var page: String?
        var onMessage: (@MainActor (JSONValue, @escaping @MainActor (JSONValue) -> Void) -> Void)?
        var openExternal: (@MainActor (URL) -> Void)?

        func receive(_ message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, JSONSerialization.isValidJSONObject(message.body),
                let data = try? JSONSerialization.data(withJSONObject: message.body),
                let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return }
            onMessage?(value) { [weak self] answer in
                self?.webView?.evaluateJavaScript(WidgetFrame.replyScript(answer), completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            let isMainFrame = action.targetFrame?.isMainFrame ?? true
            // The host page itself (`loadHTMLString`, no base URL), and the frames inside
            // it, except a link or form leaving them.
            let leaves = isMainFrame
                ? !(url?.absoluteString == "about:blank" && action.navigationType == .other)
                : action.navigationType == .linkActivated || action.navigationType == .formSubmitted
            guard leaves else { return .allow }
            if let url, action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased()) {
                openExternal?(url)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()) { openExternal?(url) }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let page { webView.loadHTMLString(page, baseURL: nil) }
        }
    }

    /// The user content controller keeps its handler: this keeps only a weak reference
    /// to the coordinator, so a widget that goes takes its coordinator with it.
    @MainActor
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(_ coordinator: Coordinator) { self.coordinator = coordinator }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.receive(message)
        }
    }
}
#endif
