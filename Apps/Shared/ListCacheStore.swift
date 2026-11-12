import Foundation
import HermesKit

/// Keeps each server's lists (`SessionListCache`) in the app's caches folder, one file a
/// server, so the next launch shows them before the server answers (`AppModel`).
@MainActor
final class ListCacheStore {
    /// A server's lists and the address they were read from: another address's are not shown.
    private struct Stored: Codable, Equatable {
        var address: String
        var cache: SessionListCache
    }

    /// Nil keeps nothing (UI tests that keep no state).
    private let folder: URL?
    private var saved: [UUID: Stored] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// The write in flight: files are written one at a time, off the main thread.
    private var writer: Task<Void, Never>?

    /// `name`: the folder in the caches folder; nil keeps nothing.
    init(name: String?) {
        folder = name.flatMap { name in
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: name, directoryHint: .isDirectory)
        }
    }

    private func file(for server: UUID) -> URL? {
        folder?.appending(path: "\(server.uuidString).json")
    }

    /// The lists kept for `server`, if they were read from `address`.
    func load(for server: UUID, address: String) -> SessionListCache? {
        guard let file = file(for: server), let data = try? Data(contentsOf: file),
            let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.address == address
        else { return nil }
        saved[server] = stored
        return stored.cache
    }

    /// Saves what `cache` returns a moment from now, once for a burst of changes, and
    /// only if it differs from the file.
    func saveSoon(for server: UUID, address: String, cache: @escaping @MainActor () -> SessionListCache) {
        guard folder != nil, pending[server] == nil else { return }
        pending[server] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.pending[server] = nil
            self.save(Stored(address: address, cache: cache()), for: server)
        }
    }

    private func save(_ stored: Stored, for server: UUID) {
        guard let file = file(for: server), saved[server] != stored else { return }
        saved[server] = stored
        let previous = writer
        writer = Task.detached(priority: .utility) {
            await previous?.value
            if stored.cache.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else if let data = try? JSONEncoder().encode(stored) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// A removed server's lists go with it.
    func forget(_ server: UUID) {
        pending[server]?.cancel()
        pending[server] = nil
        saved[server] = nil
        if let file = file(for: server) { try? FileManager.default.removeItem(at: file) }
    }

    /// Every server's lists go (a UI test starting fresh).
    func removeAll() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
}
