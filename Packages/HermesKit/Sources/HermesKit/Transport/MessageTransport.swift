import Foundation

/// A bidirectional text-frame channel (a WebSocket, in production).
///
/// The JSON-RPC client is written against this protocol only, so it can be
/// driven by `URLSessionWebSocketTransport` on device and by an in-memory
/// fake in unit tests on Linux.
public protocol MessageTransport: AnyObject, Sendable {
    /// Opens the connection. Throws if the handshake fails (bad URL, auth
    /// rejected, unreachable host).
    func connect() async throws

    /// Sends one text frame.
    func send(_ text: String) async throws

    /// Inbound text frames. The stream finishes when the connection closes
    /// normally and throws `TransportError` when it fails. It must be
    /// consumed by a single reader.
    var inbound: AsyncThrowingStream<String, any Error> { get }

    /// Closes the connection. Idempotent.
    func close() async
}

public enum TransportError: Error, Sendable, Equatable {
    case notConnected
    case closed(code: Int?, reason: String?)
    case handshakeFailed(String)
    case unsupportedFrame
}
