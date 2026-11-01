import Foundation
import HermesProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The dashboard's REST routes, with the connection's credential, for the settings that
/// live in a profile's config: capabilities (`hermes_cli/web_routers/skills.py`, `tools.py`,
/// `mcp.py`) and providers (`config_env.py`, `oauth.py`). Every route takes the profile it
/// reads or writes as `?profile=` (`apps/desktop/src/api/client.ts::capabilityScoped`).
public protocol DashboardAPI: Sendable {
    /// One call: the decoded JSON answer, or a `CronRequestError` with the dashboard's reason.
    func send(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?,
              timeout: TimeInterval?) async throws -> JSONValue
}

extension DashboardAPI {
    func get(_ path: String, profile: String?, query: [URLQueryItem] = [],
             timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await send("GET", path, query: Self.scope(profile) + query, body: nil, timeout: timeout)
    }

    func put(_ path: String, profile: String?, body: JSONValue) async throws -> JSONValue {
        try await send("PUT", path, query: Self.scope(profile), body: body, timeout: nil)
    }

    func post(_ path: String, profile: String?, body: JSONValue? = nil) async throws -> JSONValue {
        try await send("POST", path, query: Self.scope(profile), body: body, timeout: nil)
    }

    func delete(_ path: String, profile: String?, body: JSONValue? = nil) async throws -> JSONValue {
        try await send("DELETE", path, query: Self.scope(profile), body: body, timeout: nil)
    }

    private static func scope(_ profile: String?) -> [URLQueryItem] {
        profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
    }
}

enum DashboardPath {
    /// A name as one path segment.
    static func segment(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? name
    }
}

extension DashboardConnector: DashboardAPI {
    public func send(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?,
                     timeout: TimeInterval?) async throws -> JSONValue {
        try await authorized { bearer in
            var request = dashboard.request(path: path, method: method, json: body, query: query)
            if let timeout { request.timeoutInterval = timeout }
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            do {
                return try await dashboard.send(request)
            } catch {
                throw CronRequestError.from(error)
            }
        }
    }
}
