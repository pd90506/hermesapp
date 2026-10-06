import Foundation

/// Runs at most `limit` pieces of work at once; the rest wait their turn, first come
/// first served. Used to bound image downloads and decodes (`ThumbnailStore`), each
/// of which briefly holds a base64 string and its bytes.
public actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // The slot is handed over by `release`, so `running` stays as it is.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
