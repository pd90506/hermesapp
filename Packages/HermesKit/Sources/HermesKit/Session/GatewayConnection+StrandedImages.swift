import Foundation
import HermesProtocol
import Synchronization

/// An image a failed send uploaded (`image.attach_bytes`) but could not take
/// back: its `image.detach` got no answer because the socket dropped.
public struct StrandedImage: Sendable, Hashable {
    /// The runtime session whose queue holds it.
    public var sessionID: String
    public var profile: String?
    public var path: String
}

/// Stranded images ride with the next turn that starts on their session, from
/// any client (`tui_gateway/prompt_turn.py:147-149`). The runtime session can
/// outlive the outage (§7 fast reattach, or `session.resume` of a still-live
/// session), so they are detached again as soon as a socket is up, and before
/// any send on their session.
///
/// Work is per session: each session's detaches run as one flush (its images in
/// parallel), chained after that session's previous flush only. A send waits
/// for its own session's flush, never another's, and can be cancelled while it waits.
extension GatewayConnection {
    /// Oldest entries are dropped past this; an outage strands at most a
    /// message's worth (`ImageAttachmentPolicy.maxAttachments`) at a time.
    static let maxStrandedImages = 50

    func strand(_ images: [StrandedImage]) {
        for image in images where !strandedImages.contains(image) { strandedImages.append(image) }
        if strandedImages.count > Self.maxStrandedImages {
            strandedImages.removeFirst(strandedImages.count - Self.maxStrandedImages)
        }
    }

    /// Stranded paths of one runtime session, oldest first.
    public func strandedImagePaths(sessionID: String) -> [String] {
        strandedImages.filter { $0.sessionID == sessionID }.map(\.path)
    }

    /// Right after a connect or reattach: one flush per session with stranded images.
    func flushStrandedImagesInBackground() {
        guard let client else { return }
        var sessionIDs: [String] = []
        for image in strandedImages where !sessionIDs.contains(image.sessionID) { sessionIDs.append(image.sessionID) }
        for sessionID in sessionIDs { startFlush(sessionID: sessionID, using: client) }
    }

    /// Before a send on `sessionID`: detaches that session's stranded images
    /// (after any flush of the same session still running) and waits for that
    /// alone. Returns false when one still got no answer; the send must not go
    /// out, or the image would ride with it. Throws `CancellationError` as soon
    /// as the caller is cancelled; the flush itself carries on in the background.
    func clearStrandedImages(sessionID: String, using client: GatewayClient) async throws -> Bool {
        guard strandedImageFlushes[sessionID] != nil || !strandedImagePaths(sessionID: sessionID).isEmpty else {
            return true
        }
        try await waitUnlessCancelled(startFlush(sessionID: sessionID, using: client))
        return strandedImagePaths(sessionID: sessionID).isEmpty
    }

    @discardableResult
    private func startFlush(sessionID: String, using client: GatewayClient) -> Task<Void, Never> {
        let previous = strandedImageFlushes[sessionID]
        let flush = Task {
            await previous?.value
            await self.detachStrandedImages(sessionID: sessionID, using: client)
        }
        strandedImageFlushes[sessionID] = flush
        Task {
            await flush.value
            if self.strandedImageFlushes[sessionID] == flush { self.strandedImageFlushes[sessionID] = nil }
        }
        return flush
    }

    /// Takes the session's entries out first (so overlapping calls never detach
    /// one twice), detaches them in parallel, then puts back the ones whose
    /// detach got no answer, in their old order.
    private func detachStrandedImages(sessionID: String, using client: GatewayClient) async {
        let batch = strandedImages.filter { $0.sessionID == sessionID }
        guard !batch.isEmpty else { return }
        strandedImages.removeAll { $0.sessionID == sessionID }
        let unanswered = await withTaskGroup(of: StrandedImage?.self) { group in
            for image in batch {
                group.addTask { await Self.detach(image, using: client) ? nil : image }
            }
            var unanswered: Set<StrandedImage> = []
            for await image in group { if let image { unanswered.insert(image) } }
            return unanswered
        }
        strand(batch.filter(unanswered.contains))
    }

    /// False only when the request got no answer. Any answer settles the path:
    /// `detached: false` (not queued, e.g. a turn already took it) or 4001 (the
    /// runtime session is gone). `image.detach` goes through `_sess_building`,
    /// so on a lazy session it also starts the agent build (`server.py:1245-1251`);
    /// harmless, the first prompt would start it anyway.
    nonisolated static func detach(_ image: StrandedImage, using client: GatewayClient) async -> Bool {
        do {
            try await client.detachImage(sessionID: image.sessionID, profile: image.profile, path: image.path)
            return true
        } catch is RPCError {
            return true
        } catch {
            return false
        }
    }
}

/// Waits for `task`, but returns early by throwing `CancellationError` when the
/// caller is cancelled (awaiting `task.value` alone ignores cancellation).
func waitUnlessCancelled(_ task: Task<Void, Never>) async throws {
    let gate = ResumeOnce()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task {
                await task.value
                gate.resume()
            }
        }
    } onCancel: {
        gate.resume()
    }
    try Task.checkCancellation()
}

/// Resumes a continuation exactly once, whichever of "done" and "cancelled" comes first.
private final class ResumeOnce: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var resumed = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state -> Bool in
            if state.resumed { return true }
            state.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.resumed = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
