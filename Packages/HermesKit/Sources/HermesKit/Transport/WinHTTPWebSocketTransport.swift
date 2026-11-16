#if os(Windows)
import CWinHTTP
import Foundation
import Synchronization
import WinSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `MessageTransport` backed by Windows' own WinHTTP WebSocket API.
///
/// Used on Windows instead of `URLSessionWebSocketTransport`: there,
/// swift-corelibs-foundation's `URLSessionWebSocketTask` hands over a message longer than
/// about 4 KB as several separate messages (AGENTS.md, "Windows host"), and Hermes frames
/// are often longer. WinHTTP reassembles fragments itself (`*_FRAGMENT_BUFFER_TYPE` until
/// the `*_MESSAGE_BUFFER_TYPE` that ends the message).
///
/// WinHTTP is used synchronously: the handshake and sends run on a private serial queue,
/// and receiving runs on its own thread, so no blocking call ever occupies a Swift
/// concurrency thread. Like the URLSession transport, an instance is single-use.
public final class WinHTTPWebSocketTransport: MessageTransport, @unchecked Sendable {
    // @unchecked: every mutable field is behind `state` (a Mutex); the WinHTTP handles are
    // only used under the rules in `Handles`.

    private struct State {
        var handles: Handles?
        var opened = false
        var finished = false
        var closing = false
    }

    private let request: URLRequest
    private let state = Mutex(State())
    private let inboundPair = AsyncThrowingStream<String, any Error>.makeStream()
    /// Handshake, sends and the close frame, one at a time (WinHTTP allows one send at a time).
    private let queue = DispatchQueue(label: "WinHTTPWebSocketTransport")

    public var inbound: AsyncThrowingStream<String, any Error> { inboundPair.stream }

    /// - Parameter request: the fully-authenticated upgrade request, as for
    ///   `URLSessionWebSocketTransport` (URL, plus any `Sec-WebSocket-Protocol` header).
    public init(request: URLRequest) {
        self.request = request
    }

    public func connect() async throws {
        let request = self.request
        let handles: Handles = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Handles.open(request) })
            }
        }
        let alreadyFinished = state.withLock { state -> Bool in
            if state.finished { return true }
            state.handles = handles
            state.opened = true
            return false
        }
        if alreadyFinished {
            handles.closeAll()
            throw TransportError.notConnected
        }
        let thread = Thread { [self] in receiveLoop(handles) }
        thread.name = "WinHTTPWebSocketTransport.receive"
        thread.start()
    }

    public func send(_ text: String) async throws {
        guard let handles = state.withLock({ $0.opened && !$0.finished && !$0.closing ? $0.handles : nil }) else {
            throw TransportError.notConnected
        }
        let bytes = Array(text.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                let error = bytes.withUnsafeBytes { buffer -> DWORD in
                    WinHttpWebSocketSend(
                        handles.socket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                        UnsafeMutableRawPointer(mutating: buffer.baseAddress), DWORD(buffer.count))
                }
                if error == DWORD(ERROR_SUCCESS) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TransportError.closed(code: nil, reason: Handles.describe(error)))
                }
            }
        }
    }

    public func close() async {
        let handles = state.withLock { state -> Handles? in
            guard !state.finished, !state.closing else { return nil }
            state.closing = true
            return state.handles
        }
        guard let handles else {
            finish(with: nil)
            return
        }
        // Send the close frame without waiting for the server's; the receive loop ends when
        // that arrives. If it never does, abort the socket so the loop and its thread end.
        queue.async {
            _ = WinHttpWebSocketShutdown(handles.socket, USHORT(WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS.rawValue), nil, 0)
        }
        queue.asyncAfter(deadline: .now() + 5) { handles.abort() }
        finish(with: nil)
    }

    // MARK: - Receiving

    private func receiveLoop(_ handles: Handles) {
        var message: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var outcome: (any Error)?? = nil  // .some(nil) = normal close
        while outcome == nil {
            var read: DWORD = 0
            var type = WINHTTP_WEB_SOCKET_BUFFER_TYPE(rawValue: 0)
            let error = buffer.withUnsafeMutableBytes { raw in
                WinHttpWebSocketReceive(handles.socket, raw.baseAddress, DWORD(raw.count), &read, &type)
            }
            guard error == DWORD(ERROR_SUCCESS) else {
                let closing = state.withLock { $0.closing || $0.finished }
                outcome = .some(closing ? nil : TransportError.closed(code: nil, reason: Handles.describe(error)))
                break
            }
            message.append(contentsOf: buffer[0..<Int(read)])
            switch type {
            case WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE, WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE:
                continue
            case WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE:
                guard let text = String(validating: message, as: UTF8.self) else {
                    outcome = .some(TransportError.unsupportedFrame)
                    break
                }
                message.removeAll(keepingCapacity: true)
                inboundPair.continuation.yield(text)
            case WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE:
                let (code, reason) = handles.closeStatus()
                let normal = code == Int(WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS.rawValue)
                outcome = .some(normal ? nil : TransportError.closed(code: code, reason: reason))
            default:
                message.removeAll(keepingCapacity: true)
            }
        }
        handles.closeAll()
        finish(with: outcome ?? nil)
    }

    private func finish(with error: (any Error)?) {
        let first = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.finished = true
            return true
        }
        guard first else { return }
        if let error {
            inboundPair.continuation.finish(throwing: error)
        } else {
            inboundPair.continuation.finish()
        }
    }
}

/// The session, connection and WebSocket handles of one transport.
///
/// `abort()` may run while the receive thread is blocked in `WinHttpWebSocketReceive`:
/// closing the WebSocket handle cancels that call, which is how WinHTTP stops a blocking
/// receive. `closeAll()` runs once the receive loop is done with the handles.
private final class Handles: @unchecked Sendable {
    // @unchecked: the handles are written once in `open`; closing is serialised by `lock`.
    let session: HINTERNET
    let connection: HINTERNET
    let socket: HINTERNET
    private let lock = Mutex((socketClosed: false, allClosed: false))

    private init(session: HINTERNET, connection: HINTERNET, socket: HINTERNET) {
        self.session = session
        self.connection = connection
        self.socket = socket
    }

    /// Opens the connection and completes the WebSocket upgrade. Blocking.
    static func open(_ request: URLRequest) throws -> Handles {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host
        else { throw TransportError.handshakeFailed("invalid URL") }
        let secure: Bool
        switch components.scheme?.lowercased() {
        case "wss", "https": secure = true
        case "ws", "http": secure = false
        default: throw TransportError.handshakeFailed("unsupported scheme \(components.scheme ?? "")")
        }
        let port = components.port ?? (secure ? 443 : 80)
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }

        guard let session = WinHttpOpen("Talaria".wide, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0) else {
            throw TransportError.handshakeFailed(describe(GetLastError()))
        }
        // Handshake limits (ms): resolve, connect, send, receive. The socket itself has no
        // receive timeout (set after the upgrade): the gateway's heartbeat watches liveness.
        WinHttpSetTimeouts(session, 0, 30_000, 30_000, 30_000)
        guard let connection = WinHttpConnect(session, host.wide, INTERNET_PORT(port), 0) else {
            let error = GetLastError()
            WinHttpCloseHandle(session)
            throw TransportError.handshakeFailed(describe(error))
        }
        func fail(_ message: String, _ handles: HINTERNET?...) -> TransportError {
            for handle in handles { if let handle { WinHttpCloseHandle(handle) } }
            WinHttpCloseHandle(connection)
            WinHttpCloseHandle(session)
            return TransportError.handshakeFailed(message)
        }
        guard let upgrade = WinHttpOpenRequest(
            connection, "GET".wide, target.wide, nil, nil, nil, secure ? DWORD(WINHTTP_FLAG_SECURE) : 0)
        else { throw fail(describe(GetLastError())) }
        guard WinHttpSetOption(upgrade, DWORD(WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET), nil, 0) else {
            throw fail(describe(GetLastError()), upgrade)
        }
        let headers = (request.allHTTPHeaderFields ?? [:])
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()
        if !headers.isEmpty {
            let added = headers.withCString(encodedAs: UTF16.self) {
                WinHttpAddRequestHeaders(upgrade, $0, DWORD.max, DWORD(WINHTTP_ADDREQ_FLAG_ADD))
            }
            guard added else { throw fail(describe(GetLastError()), upgrade) }
        }
        guard WinHttpSendRequest(upgrade, nil, 0, nil, 0, 0, 0), WinHttpReceiveResponse(upgrade, nil) else {
            throw fail(describe(GetLastError()), upgrade)
        }
        var status: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        _ = WinHttpQueryHeaders(
            upgrade, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER), nil, &status, &size, nil)
        guard status == 101 else {
            throw fail("HTTP \(status)", upgrade)
        }
        guard let socket = WinHttpWebSocketCompleteUpgrade(upgrade, 0) else {
            throw fail(describe(GetLastError()), upgrade)
        }
        WinHttpCloseHandle(upgrade)
        var noTimeout: DWORD = 0
        WinHttpSetOption(socket, DWORD(WINHTTP_OPTION_RECEIVE_TIMEOUT), &noTimeout, DWORD(MemoryLayout<DWORD>.size))
        return Handles(session: session, connection: connection, socket: socket)
    }

    /// The close code and reason the server sent.
    func closeStatus() -> (Int?, String?) {
        var status: USHORT = 0
        var reason = [UInt8](repeating: 0, count: 123)  // the protocol's maximum reason length
        var consumed: DWORD = 0
        let error = reason.withUnsafeMutableBytes {
            WinHttpWebSocketQueryCloseStatus(socket, &status, $0.baseAddress, DWORD($0.count), &consumed)
        }
        guard error == DWORD(ERROR_SUCCESS) else { return (nil, nil) }
        let text = String(decoding: reason[0..<Int(consumed)], as: UTF8.self)
        return (Int(status), text.isEmpty ? nil : text)
    }

    /// Cancels a blocking receive by closing the WebSocket handle.
    func abort() {
        let close = lock.withLock { state -> Bool in
            guard !state.socketClosed else { return false }
            state.socketClosed = true
            return true
        }
        if close { WinHttpCloseHandle(socket) }
    }

    func closeAll() {
        abort()
        let close = lock.withLock { state -> Bool in
            guard !state.allClosed else { return false }
            state.allClosed = true
            return true
        }
        if close {
            WinHttpCloseHandle(connection)
            WinHttpCloseHandle(session)
        }
    }

    static func describe(_ error: DWORD) -> String {
        switch Int32(bitPattern: error) {
        case ERROR_WINHTTP_CANNOT_CONNECT: return "cannot connect"
        case ERROR_WINHTTP_NAME_NOT_RESOLVED: return "host not found"
        case ERROR_WINHTTP_TIMEOUT: return "timed out"
        case ERROR_WINHTTP_SECURE_FAILURE: return "TLS failure"
        case ERROR_WINHTTP_OPERATION_CANCELLED: return "cancelled"
        case ERROR_WINHTTP_CONNECTION_ERROR: return "connection reset"
        default: return "WinHTTP error \(error)"
        }
    }
}

private extension String {
    /// A NUL-terminated UTF-16 copy, for WinHTTP's `LPCWSTR` parameters.
    var wide: [WCHAR] { Array(utf16) + [0] }
}
#endif
