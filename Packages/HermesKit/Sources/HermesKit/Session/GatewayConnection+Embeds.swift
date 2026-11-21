import Foundation
import HermesProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A text file read on the gateway (`GatewayConnection.readText`).
public struct GatewayTextFile: Sendable, Hashable {
    public var text: String
    public var binary: Bool
    /// `/api/fs/read-text` returns at most `_FS_TEXT_PREVIEW_MAX_BYTES`: a longer file is cut.
    public var truncated: Bool

    public init(text: String, binary: Bool, truncated: Bool) {
        self.text = text
        self.binary = binary
        self.truncated = truncated
    }
}

public enum EmbedReadError: Error, Sendable, Equatable {
    case noText
    case noImage
}

/// What replies embed: the page of a `::preview` widget and web images the gateway
/// fetches (`docs/protocol.md` §10.11), as hermes-core's `readGatewayText` and
/// `proxiedImageDataURL` read them.
extension GatewayConnection {
    /// A text file on the gateway, as Desktop's remote mode reads a `::preview` page
    /// (`readDesktopFileText`): `GET /api/fs/read-text?path=&profile=&session_id=` →
    /// `{text, binary, truncated}` (`hermes_cli/web_routers/files.py`). `sessionKey` (a
    /// stored key) is sent only for a relative path, which resolves against that chat's
    /// folder. Throws `GatewayClientError.notConnected` without REST access.
    public func readText(path: String, profile: String?, sessionKey: String?) async throws -> GatewayTextFile {
        guard let api = dashboardAPI else { throw GatewayClientError.notConnected }
        return try await Self.readText(api, path: path, profile: profile, sessionKey: sessionKey)
    }

    static func readText(_ api: any DashboardAPI, path: String, profile: String?,
                         sessionKey: String?) async throws -> GatewayTextFile {
        var query = [URLQueryItem(name: "path", value: path)]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        if let sessionKey, PreviewTarget.isRelative(path) {
            query.append(URLQueryItem(name: "session_id", value: sessionKey))
        }
        let answer = try await api.send("GET", "/api/fs/read-text", query: query, body: nil, timeout: 60)
        guard let text = answer["text"]?.stringValue else { throw EmbedReadError.noText }
        return GatewayTextFile(text: text, binary: answer["binary"]?.boolValue == true,
                               truncated: answer["truncated"]?.boolValue == true)
    }

    /// A web image the gateway fetches for the app, as Desktop retries one this device
    /// could not load: `GET /api/media/proxy?url=` → `{data_url}` (only the gateway's
    /// allowlisted image hosts). The image's bytes.
    public func proxiedImage(_ url: URL) async throws -> Data {
        guard let api = dashboardAPI else { throw GatewayClientError.notConnected }
        return try await Self.proxiedImage(api, url: url)
    }

    static func proxiedImage(_ api: any DashboardAPI, url: URL) async throws -> Data {
        let answer = try await api.send("GET", "/api/media/proxy",
                                        query: [URLQueryItem(name: "url", value: url.absoluteString)],
                                        body: nil, timeout: 60)
        guard let dataURL = answer["data_url"]?.stringValue, dataURL.hasPrefix("data:image/"),
            let data = DataURL.decode(dataURL), !data.isEmpty
        else { throw EmbedReadError.noImage }
        return data
    }
}
