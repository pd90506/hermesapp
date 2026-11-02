import Foundation
import HermesKit
import Network

/// The loopback end of a browser sign-in (`NativeSignIn`, RFC 8252): an HTTP listener on
/// `127.0.0.1`, on a port the system picks, that waits for the browser to come back to
/// `/callback` and answers it with a short page. Other requests (a favicon) get a 404 and
/// the wait goes on. Apple-only (Network.framework), so not in the package.
final class LoopbackRedirect: @unchecked Sendable {
    // Safe: every mutable field is read and written only on `queue`.
    private let queue = DispatchQueue(label: "talaria.loopback-redirect")
    private let listener: NWListener
    private var waiter: CheckedContinuation<URL, any Error>?
    private var received: Result<URL, any Error>?
    private var readyWaiter: CheckedContinuation<UInt16, any Error>?

    /// Starts listening; answers with the port once the listener is ready.
    static func start() async throws -> (LoopbackRedirect, UInt16) {
        let redirect = try LoopbackRedirect()
        let port = try await redirect.ready()
        return (redirect, port)
    }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    private func ready() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            readyWaiter = continuation
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    /// On `queue`.
    private func listenerChanged(_ state: NWListener.State) {
        guard let waiter = readyWaiter else { return }
        switch state {
        case .ready:
            readyWaiter = nil
            waiter.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let error):
            readyWaiter = nil
            waiter.resume(throwing: error)
        case .cancelled:
            readyWaiter = nil
            waiter.resume(throwing: CancellationError())
        default:
            break
        }
    }

    /// The URL the browser came back to (`/callback?code=…&state=…`).
    func callback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let received = self.received {
                        continuation.resume(with: received)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, any Error>) {
        queue.async {
            guard self.received == nil else { return }
            self.received = result
            self.waiter?.resume(with: result)
            self.waiter = nil
            self.listener.cancel()
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let url = data.flatMap(Self.requestURL)
            let isCallback = url.map(NativeSignIn.isCallback) ?? false
            let response = isCallback ? Self.page : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let url { self.finish(.success(url)) }
        }
    }

    /// The target of the request line (`GET /callback?code=… HTTP/1.1`), on this listener.
    private static func requestURL(_ data: Data) -> URL? {
        guard let head = String(data: data.prefix(8 * 1024), encoding: .utf8)?.split(separator: "\r\n").first else { return nil }
        let parts = head.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return URL(string: "http://127.0.0.1\(parts[1])")
    }

    private static let page: String = {
        let body = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">\
            <title>Talaria</title></head><body style="font: 17px -apple-system, sans-serif; text-align: center; \
            padding-top: 20vh">Signed in. You can close this page and go back to Talaria.</body></html>
            """
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
            + "Content-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n" + body
    }()
}
