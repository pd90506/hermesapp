import Foundation
import Testing

@testable import HermesKit

@Suite struct LocalBackendTests {
    @Test func readsThePortFromEitherAnnouncement() {
        #expect(LocalBackend.readyPort(in: "starting\nHERMES_BACKEND_READY port=54804\n") == 54804)
        #expect(LocalBackend.readyPort(in: "HERMES_DASHBOARD_READY port=9119") == 9119)
        // uvicorn's stderr chunk without a newline (backend-ready.ts:7-12).
        #expect(LocalBackend.readyPort(in: "INFO: Started server process [4711]HERMES_BACKEND_READY port=65238") == 65238)
        #expect(LocalBackend.readyPort(in: "XHERMES_BACKEND_READY port=1") == nil)
        #expect(LocalBackend.readyPort(in: "HERMES_BACKEND_READY port=") == nil)
        #expect(LocalBackend.readyPort(in: "HERMES_BACKEND_READY port=99999") == nil)
        #expect(LocalBackend.readyPort(in: "Hermes backend already running on this host: PID 3619, port 9139.") == nil)
    }

    @Test func findsHermesInTheInstallDirectoriesBeforePATH() {
        let env = ["PATH": "/usr/bin:/custom/bin"]
        let found = LocalBackend.findHermes(environment: env, home: "/Users/me") {
            ["/custom/bin/hermes", "/opt/homebrew/bin/hermes"].contains($0)
        }
        #expect(found?.path == "/opt/homebrew/bin/hermes")
        let onPath = LocalBackend.findHermes(environment: env, home: "/Users/me") { $0 == "/custom/bin/hermes" }
        #expect(onPath?.path == "/custom/bin/hermes")
        #expect(LocalBackend.findHermes(environment: env, home: "/Users/me") { _ in false } == nil)
    }

    @Test func launchesAnIsolatedLoopbackServeWithTheTokenAndParent() {
        let launch = LocalBackend.launch(
            hermes: URL(fileURLWithPath: "/Users/me/.local/bin/hermes"), token: "tok", parentPID: 42,
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me", "HERMES_PARENT_NONCE": "stale"],
            home: "/Users/me")
        #expect(launch.arguments == ["serve", "--host", "127.0.0.1", "--port", "0", "--isolated"])
        #expect(launch.environment["HERMES_DASHBOARD_SESSION_TOKEN"] == "tok")
        #expect(launch.environment["HERMES_PARENT_PID"] == "42")
        #expect(launch.environment["HERMES_PARENT_NONCE"] == nil)
        #expect(launch.environment["HOME"] == "/Users/me")
        #expect(launch.environment["PATH"]
            == "/Users/me/.local/bin:/Users/me/.hermes/hermes-agent/.hermes/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    @Test func tokensAreURLSafeAndFresh() {
        let a = LocalBackend.makeToken(), b = LocalBackend.makeToken()
        #expect(a != b)
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    #if os(macOS) || os(Linux)
    /// A stand-in backend: a shell script, so no socket is opened.
    private func fake(_ script: String) -> LocalBackendProcess {
        LocalBackendProcess { token in
            LocalBackend.Launch(executable: URL(fileURLWithPath: "/bin/sh"),
                                arguments: ["-c", script], environment: ["TOKEN": token])
        }
    }

    @Test(.timeLimit(.minutes(1))) func startsWaitsForThePortAndStops() async throws {
        let backend = fake(#"echo "warming up"; sleep 0.2; echo "HERMES_BACKEND_READY port=4321"; exec sleep 30"#)
        let running = try await backend.start()
        #expect(running.port == 4321)
        #expect(running.url == "http://127.0.0.1:4321")
        #expect(await backend.isRunning)
        // Started again while running: the same backend.
        #expect(try await backend.start() == running)
        await backend.stop()
        #expect(await !backend.isRunning)
    }

    @Test(.timeLimit(.minutes(1))) func reportsAnEarlyExitWithItsOutput() async {
        let backend = fake(#"echo "Hermes backend already running on this host"; exit 3"#)
        await #expect(throws: LocalBackend.Failure.exited(status: 3, output: "Hermes backend already running on this host\n")) {
            try await backend.start()
        }
    }

    @Test(.timeLimit(.minutes(1))) func givesUpAfterTheTimeout() async {
        let backend = fake("exec sleep 30")
        await #expect(throws: LocalBackend.Failure.timedOut(output: "")) {
            try await backend.start(timeout: .milliseconds(300))
        }
        await backend.stop()
    }

    @Test(.timeLimit(.minutes(1))) func restartsAfterTheBackendDied() async throws {
        let backend = fake(#"echo "HERMES_BACKEND_READY port=$$"; sleep 0.3"#)
        let first = try await backend.start()
        try await Task.sleep(for: .seconds(1))
        #expect(await !backend.isRunning)
        let second = try await backend.start()
        #expect(second.token != first.token)
        await backend.stop()
    }
    #endif
}
