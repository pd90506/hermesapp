import Foundation
import HermesKit
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A real Hermes dashboard to test against, read from a git-ignored env file at
/// the repo root (`.env.live-local`, `.env.live-remote`). Live tests run only
/// when `HERMES_LIVE=1`, which `scripts/live-test.sh` sets: a plain `swift test`
/// and CI never open a real socket.
///
/// File keys: `HERMES_LIVE_URL`, then either `HERMES_LIVE_TOKEN` (un-gated
/// loopback dashboard, sent as `?token=`) or `HERMES_LIVE_USERNAME` +
/// `HERMES_LIVE_PASSWORD` (gated dashboard, `basic` provider).
struct LiveServer: Sendable, CustomTestStringConvertible {
    /// Every test runs in this profile, never in the user's own ones.
    /// (`test` itself is a reserved profile name in Hermes.)
    static let profile = "hermesapp-test"
    /// Title prefix of chats the tests create, so leftovers are easy to spot.
    static let chatPrefix = "hermesapp-test"

    let name: String
    let endpoint: GatewayEndpoint
    let credential: GatewayCredential

    var testDescription: String { name }

    static let enabled = ProcessInfo.processInfo.environment["HERMES_LIVE"] == "1"

    /// The servers whose env file exists, local first.
    static let all: [LiveServer] = {
        guard enabled else { return [] }
        return [("local", ".env.live-local"), ("remote", ".env.live-remote")].compactMap { name, file in
            load(name: name, file: repoRoot.appendingPathComponent(file))
        }
    }()

    func connector() -> DashboardConnector {
        DashboardConnector(endpoint: endpoint, credential: credential)
    }

    private static var repoRoot: URL {
        // Packages/HermesKit/Tests/HermesLiveTests/LiveServer.swift → the repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func load(name: String, file: URL) -> LiveServer? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        guard let url = values["HERMES_LIVE_URL"], let endpoint = try? GatewayEndpoint(url) else { return nil }
        if let token = values["HERMES_LIVE_TOKEN"], !token.isEmpty {
            return LiveServer(name: name, endpoint: endpoint, credential: .sessionToken(token))
        }
        if let user = values["HERMES_LIVE_USERNAME"], let password = values["HERMES_LIVE_PASSWORD"],
            !user.isEmpty, !password.isEmpty
        {
            return LiveServer(name: name, endpoint: endpoint,
                              credential: .password(provider: "basic", username: user, password: password))
        }
        return nil
    }
}

struct LiveTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(30),
               _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw LiveTimeout(what: what) }
        try await Task.sleep(for: .milliseconds(200))
    }
}
