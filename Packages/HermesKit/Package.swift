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
    ],
    targets: [
        // Pure Codable wire types: JSON-RPC envelope, JSONValue, gateway
        // methods/events/server-requests. Depends on Foundation only.
        .target(name: "HermesProtocol"),
        // Transport abstraction, URLSession WebSocket transport, the
        // JSON-RPC client (id correlation + dispatch), auth, session state.
        .target(name: "HermesKit", dependencies: ["HermesProtocol"]),
        .testTarget(name: "HermesProtocolTests", dependencies: ["HermesProtocol"]),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"]),
    ],
    swiftLanguageModes: [.v6]
)
