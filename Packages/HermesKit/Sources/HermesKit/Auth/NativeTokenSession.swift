import Foundation

/// The current native token pair for one server, refreshed through
/// `/auth/native/refresh` when the access token expires.
///
/// Create one per configured server and keep it for the app's lifetime,
/// so every `DashboardConnector` for that server (reconnects, foreground
/// connects) shares it. Persisting is the app's job: `onRotate` receives each
/// new pair and finishes before any request uses it.
///
/// Refreshes are single-flight: concurrent callers that saw the same rejected
/// access token share one `/auth/native/refresh` call. Replaying a rotated
/// refresh token is fatal on providers with reuse detection; Hermes only
/// coalesces same-token refreshes for 30 s
/// (`hermes_cli/dashboard_auth/refresh_singleflight.py:1-11,24-29`), so the
/// client must not rely on it.
public actor NativeTokenSession {
    public private(set) var tokens: NativeTokens

    private let refreshMargin: TimeInterval
    private let now: @Sendable () -> Date
    private let onRotate: @Sendable (NativeTokens) async -> Void
    private var inFlight: Task<NativeTokens, any Error>?

    /// - Parameters:
    ///   - refreshMargin: refresh before a request when `expiresAt` is
    ///     within this many seconds.
    ///   - onRotate: called with every refreshed pair; save it here.
    public init(
        tokens: NativeTokens,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init,
        onRotate: @escaping @Sendable (NativeTokens) async -> Void = { _ in }
    ) {
        self.tokens = tokens
        self.refreshMargin = refreshMargin
        self.now = now
        self.onRotate = onRotate
    }

    /// An access token to use now, refreshed first if it is known to be
    /// expired. `refreshed` is true when this call did (or joined) a refresh.
    func accessToken(using dashboard: DashboardClient) async throws -> (token: String, refreshed: Bool) {
        if let expiresAt = tokens.expiresAt, now().timeIntervalSince1970 >= expiresAt - refreshMargin {
            return (try await refresh(replacing: tokens.accessToken, using: dashboard), true)
        }
        return (tokens.accessToken, false)
    }

    /// Replaces `rejected` with a fresh access token. If another caller
    /// already rotated it, returns the current token without a new request.
    ///
    /// Throws `DashboardError.refreshRejected` when the server no longer
    /// accepts the refresh token: the user has to sign in again.
    func refresh(replacing rejected: String, using dashboard: DashboardClient) async throws -> String {
        if tokens.accessToken != rejected { return tokens.accessToken }
        if let inFlight { return try await inFlight.value.accessToken }
        let current = tokens
        guard !current.refreshToken.isEmpty else { throw DashboardError.refreshRejected }
        let onRotate = onRotate
        let task = Task {
            var fresh = try await dashboard.refreshNativeTokens(refreshToken: current.refreshToken,
                                                                provider: current.provider ?? "")
            if fresh.provider == nil { fresh.provider = current.provider }
            await onRotate(fresh)
            return fresh
        }
        inFlight = task
        do {
            let fresh = try await task.value
            tokens = fresh
            inFlight = nil
            return fresh.accessToken
        } catch {
            inFlight = nil
            throw error
        }
    }
}

extension NativeTokenSession: Hashable {
    // Identity: two sessions are the same credential only if they are the same object.
    public nonisolated static func == (lhs: NativeTokenSession, rhs: NativeTokenSession) -> Bool { lhs === rhs }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
