// swift-tools-version: 6.2
// Tools version 6.2 is what Xcode 26 ships; keep it at or below the Mac's
// Xcode so the same manifest resolves on both hosts.
import PackageDescription

let package = Package(
    name: "HermesKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "HermesProtocol", targets: ["HermesProtocol"]),
        .library(name: "HermesKit", targets: ["HermesKit"]),
        // The C interface the Flutter desktop app loads (docs/desktop-bridge.md).
        .library(name: "HermesBridge", type: .dynamic, targets: ["HermesBridge"]),
    ],
    targets: [
        // Pure Codable wire types: JSON-RPC envelope, JSONValue, gateway
        // methods/events/server-requests. Depends on Foundation only.
        .target(name: "HermesProtocol"),
        // Transport abstraction, URLSession WebSocket transport, the
        // JSON-RPC client (id correlation + dispatch), auth, session state.
        .target(name: "HermesKit", dependencies: [
            "HermesProtocol",
            .target(name: "CWinHTTP", condition: .when(platforms: [.windows])),
        ]),
        // WinHTTP from the Windows SDK, for the Windows WebSocket transport
        // (`WinHTTPWebSocketTransport`). A system header module: nothing is compiled,
        // and it is used only on Windows. See AGENTS.md "Windows host".
        .systemLibrary(name: "CWinHTTP"),
        // A thin C interface over HermesKit for the Flutter desktop app: JSON commands in,
        // JSON snapshots and replies out. No logic of its own (docs/desktop-bridge.md).
        .target(name: "HermesBridge", dependencies: ["HermesKit"]),
        .testTarget(name: "HermesBridgeTests", dependencies: ["HermesBridge"]),
        .testTarget(name: "HermesProtocolTests", dependencies: ["HermesProtocol"]),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"]),
        // Opt-in end-to-end tests against real Hermes dashboards. Skipped unless
        // HERMES_LIVE=1 (set by scripts/live-test.sh); see AGENTS.md.
        .testTarget(name: "HermesLiveTests", dependencies: ["HermesKit"]),
    ],
    swiftLanguageModes: [.v6]
)
