import Foundation
import Synchronization

#if canImport(Glibc)
import Glibc
#endif

/// A Hermes backend on this computer that the app starts and stops itself, as Hermes
/// Desktop does (`apps/desktop/electron/main.ts:12196-12260`): `hermes serve` on a
/// loopback port the OS picks, signed in with a token the app makes for each start.
///
/// - `--isolated`: without it, `hermes serve` attaches to a backend already serving
///   this host and exits instead of binding (`hermes_cli/main_dashboard.py:893-935`).
/// - `HERMES_DASHBOARD_SESSION_TOKEN`: the token the backend accepts as `?token=`
///   (`hermes_cli/web_server.py:380-383`).
/// - `HERMES_PARENT_PID`: the backend exits soon after the app does, even after a crash
///   (`hermes_cli/web_server_lifecycle.py:326-365`).
/// - The port: printed as `HERMES_BACKEND_READY port=<n>` once bound
///   (`apps/desktop/electron/backend-ready.ts:3-12`).
public enum LocalBackend {
    public struct Launch: Sendable, Equatable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
    }

    /// The backend once it is listening.
    public struct Running: Sendable, Equatable {
        public var port: Int
        public var token: String
        public var url: String { "http://127.0.0.1:\(port)" }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// No `hermes` executable in the usual places.
        case hermesNotFound
        case launchFailed(String)
        /// The backend exited before it said which port it listens on.
        case exited(status: Int32, output: String)
        case timedOut(output: String)

        public var errorDescription: String? {
            switch self {
            case .hermesNotFound:
                "Hermes isn't installed on this Mac (no `hermes` in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin or PATH)."
            case .launchFailed(let message): "Couldn't start Hermes: \(message)"
            case .exited(let status, let output):
                "Hermes exited (status \(status)) before it was ready." + Self.tail(output)
            case .timedOut(let output): "Hermes didn't get ready in time." + Self.tail(output)
            }
        }

        private static func tail(_ output: String) -> String {
            let lines = output.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
            return lines.isEmpty ? "" : "\n\(lines)"
        }
    }

    /// Directories a `hermes` install lands in, besides PATH (an app opened from the
    /// Finder gets only the system PATH).
    public static func installDirectories(home: String) -> [String] {
        ["\(home)/.local/bin", "\(home)/.hermes/hermes-agent/.hermes/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// The `hermes` executable: the install directories first, then PATH.
    public static func findHermes(environment: [String: String], home: String,
                                  isExecutable: (String) -> Bool) -> URL? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in installDirectories(home: home) + path where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent("hermes")
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    public static func launch(hermes: URL, token: String, parentPID: Int32,
                              environment: [String: String], home: String) -> Launch {
        var env = environment
        env["HERMES_DASHBOARD_SESSION_TOKEN"] = token
        env["HERMES_PARENT_PID"] = String(parentPID)
        // A marker without a matching nonce disarms the watchdog (web_server_lifecycle.py:345-353).
        env["HERMES_PARENT_START_MARKER"] = nil
        env["HERMES_PARENT_NONCE"] = nil
        // Tools Hermes runs (git, node, …) are usually in the install directories too.
        let path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (installDirectories(home: home).filter { !path.contains($0) } + path).joined(separator: ":")
        return Launch(executable: hermes,
                      arguments: ["serve", "--host", "127.0.0.1", "--port", "0", "--isolated"],
                      environment: env)
    }

    /// The port in the backend's output, once it has said it.
    /// Matched on a word boundary: stderr chunks can run into the line without a newline
    /// (`backend-ready.ts:7-12`).
    public static func readyPort(in output: String) -> Int? {
        for marker in ["HERMES_BACKEND_READY port=", "HERMES_DASHBOARD_READY port="] {
            var searchStart = output.startIndex
            while let range = output.range(of: marker, range: searchStart..<output.endIndex) {
                searchStart = range.upperBound
                if range.lowerBound > output.startIndex {
                    let before = output[output.index(before: range.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" { continue }
                }
                let digits = output[range.upperBound...].prefix(while: \.isASCIIDigit)
                if let port = Int(digits), (1...65535).contains(port) { return port }
            }
        }
        return nil
    }

    /// A fresh session token: 32 random bytes, base64url.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

#if os(macOS) || os(Linux)
/// One `hermes serve` the app owns: started on demand, stopped on request or when the
/// app quits.
public actor LocalBackendProcess {
    private var process: Process?
    private var running: LocalBackend.Running?
    /// The child's pid, for `terminateNow()` from a synchronous app-quit handler.
    private let pid = Mutex<Int32?>(nil)
    private let launchFor: @Sendable (String) throws -> LocalBackend.Launch

    /// - Parameter launch: what to run for a token (`LocalBackend.launch`, or a fake in tests).
    public init(launch: @escaping @Sendable (String) throws -> LocalBackend.Launch) {
        self.launchFor = launch
    }

    /// Starts `hermes` from its usual places with this process as the parent.
    public static func hermes() -> LocalBackendProcess {
        LocalBackendProcess { token in
            let env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard let hermes = LocalBackend.findHermes(environment: env, home: home,
                                                       isExecutable: FileManager.default.isExecutableFile(atPath:))
            else { throw LocalBackend.Failure.hermesNotFound }
            return LocalBackend.launch(hermes: hermes, token: token, parentPID: getpid(),
                                       environment: env, home: home)
        }
    }

    public var isRunning: Bool { process?.isRunning == true && running != nil }

    /// The running backend, started first if needed. Waits until it says its port.
    public func start(timeout: Duration = .seconds(90)) async throws -> LocalBackend.Running {
        if let running, process?.isRunning == true { return running }
        stopNow()
        let token = LocalBackend.makeToken()
        let launch = try launchFor(token)

        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let output = OutputTail()
        let (events, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        // Always drained, also after start: a full pipe would block the backend.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let port = output.append(data) { continuation.yield(.ready(port)) }
        }
        process.terminationHandler = { process in
            continuation.yield(.exited(process.terminationStatus))
            continuation.finish()
        }
        do {
            try process.run()
        } catch {
            throw LocalBackend.Failure.launchFailed(error.localizedDescription)
        }
        self.process = process
        pid.withLock { $0 = process.processIdentifier }

        let port = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .ready(let port): return port
                    case .exited(let status):
                        // The last output can still be on its way through the pipe.
                        try? await Task.sleep(for: .milliseconds(100))
                        throw LocalBackend.Failure.exited(status: status, output: output.text)
                    }
                }
                throw LocalBackend.Failure.exited(status: -1, output: output.text)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LocalBackend.Failure.timedOut(output: output.text)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let running = LocalBackend.Running(port: port, token: token)
        self.running = running
        return running
    }

    /// Stops the backend and waits briefly for it to go.
    public func stop() async {
        guard let process else { return }
        stopNow()
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func stopNow() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        running = nil
        pid.withLock { $0 = nil }
    }

    /// For a synchronous app-quit handler: asks the backend to stop, without waiting.
    /// (If the app dies first, the backend's parent watchdog stops it.)
    public nonisolated func terminateNow() {
        if let pid = pid.withLock({ $0 }) { kill(pid, SIGTERM) }
    }

    private enum Event: Sendable {
        case ready(Int)
        case exited(Int32)
    }
}

/// The last few KB of the backend's output, and whether it has said its port.
private final class OutputTail: Sendable {
    private let state = Mutex<(text: String, port: Int?)>(("", nil))

    /// Appends a chunk; returns the port the first time it shows up.
    func append(_ data: Data) -> Int? {
        state.withLock { state in
            state.text += String(decoding: data, as: UTF8.self)
            if state.text.count > 8192 { state.text = String(state.text.suffix(8192)) }
            guard state.port == nil, let port = LocalBackend.readyPort(in: state.text) else { return nil }
            state.port = port
            return port
        }
    }

    var text: String { state.withLock { $0.text } }
}
#endif
