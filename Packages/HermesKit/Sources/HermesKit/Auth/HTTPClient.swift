import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so dashboard auth can be unit-tested with a fake.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The response body saved to a new temporary file, which the caller moves or deletes.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

extension HTTPClient {
    /// Through memory: for fakes, and clients that cannot stream to disk.
    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return (url, response)
    }
}

/// `HTTPClient` backed by a `URLSession`. Its cookie storage holds the
/// dashboard session cookies after a password login.
// @unchecked: URLSession is thread-safe but not annotated Sendable on every platform.
public struct URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// A client with its own in-memory cookie jar and no disk cache. Use one per
    /// server: the dashboard's session cookies (30-day refresh token) then never
    /// reach the app-wide, disk-persisted `HTTPCookieStorage.shared` and are not
    /// shared between configured servers.
    public static func ephemeral() -> URLSessionHTTPClient {
        URLSessionHTTPClient(session: URLSession(configuration: .ephemeral))
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    #if !canImport(FoundationNetworking)
    /// Streamed to disk: a delivered file can be large. URLSession deletes its own
    /// file when this returns, so it is moved to one the caller owns.
    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (location, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: location)
            throw URLError(.badServerResponse)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: location, to: url)
        return (url, http)
    }
    #endif
}
