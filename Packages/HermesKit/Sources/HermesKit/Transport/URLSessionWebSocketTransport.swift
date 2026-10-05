import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `MessageTransport` backed by `URLSessionWebSocketTask`.
///
/// Works on Apple platforms and on Linux (swift-corelibs-foundation ships
/// `URLSessionWebSocketTask` in `FoundationNetworking`). A transport instance
/// is single-use: create a new one per connection attempt, because the
/// gateway's auth ticket is single-use too.
public final class URLSessionWebSocketTransport: NSObject, MessageTransport, @unchecked Sendable {
    private struct State {
        var task: URLSessionWebSocketTask?
        var openContinuation: CheckedContinuation<Void, any Error>?
        var opened = false
        var finished = false
    }

    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let state = Mutex(State())
    private let inboundPair = AsyncThrowingStream<String, any Error>.makeStream()
    // Created lazily in connect() so the delegate (self) is fully initialised.
    private let session = Mutex<URLSession?>(nil)

    public var inbound: AsyncThrowingStream<String, any Error> { inboundPair.stream }

    /// - Parameters:
    ///   - request: The fully-authenticated upgrade request (URL, and the
    ///     `Sec-WebSocket-Protocol` header when using ticket auth). Build it
    ///     with `GatewayEndpoint.webSocketRequest(ticket:)`.
    ///   - configuration: ephemeral by default: the socket needs no cookies, and
    ///     nothing about it (URL with a ticket/token) should be cached on disk.
    public init(request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) {
        self.request = request
        self.configuration = configuration
        super.init()
    }

    public func connect() async throws {
        let urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session.withLock { $0 = urlSession }
        let task = urlSession.webSocketTask(with: request)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let alreadyFinished = state.withLock { state -> Bool in
                if state.finished { return true }
                state.task = task
                state.openContinuation = continuation
                return false
            }
            if alreadyFinished {
                continuation.resume(throwing: TransportError.notConnected)
                return
            }
            task.resume()
        }
        receiveLoop(task)
    }

    public func send(_ text: String) async throws {
        guard let task = state.withLock({ $0.opened && !$0.finished ? $0.task : nil }) else {
            throw TransportError.notConnected
        }
        try await task.send(.string(text))
    }

    public func close() async {
        let task = state.withLock { $0.task }
        task?.cancel(with: .normalClosure, reason: nil)
        finish(with: nil)
    }

    // MARK: - Internals

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.inboundPair.continuation.yield(text)
                self.receiveLoop(task)
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8) {
                    self.inboundPair.continuation.yield(text)
                    self.receiveLoop(task)
                } else {
                    self.finish(with: TransportError.unsupportedFrame)
                }
            case .success:
                self.receiveLoop(task)
            case .failure(let error):
                let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
                if code == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue {
                    self.finish(with: nil)
                } else {
                    self.finish(with: TransportError.closed(code: code, reason: error.localizedDescription))
                }
            }
        }
    }

    private func finish(with error: (any Error)?) {
        let pending = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.openContinuation = nil }
            return state.openContinuation
        }
        pending?.resume(throwing: error ?? TransportError.closed(code: nil, reason: nil))
        if let error {
            inboundPair.continuation.finish(throwing: error)
        } else {
            inboundPair.continuation.finish()
        }
        session.withLock { $0?.invalidateAndCancel(); $0 = nil }
    }
}

extension URLSessionWebSocketTransport: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let pending = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            state.opened = true
            defer { state.openContinuation = nil }
            return state.openContinuation
        }
        pending?.resume()
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        if closeCode == .normalClosure {
            finish(with: nil)
        } else {
            finish(with: TransportError.closed(code: closeCode.rawValue, reason: reasonText))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let wasOpened = state.withLock { $0.opened }
        guard let error else { finish(with: nil); return }
        if wasOpened {
            finish(with: TransportError.closed(code: nil, reason: error.localizedDescription))
        } else {
            finish(with: TransportError.handshakeFailed(error.localizedDescription))
        }
    }
}
