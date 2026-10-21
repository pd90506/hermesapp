import Foundation
import HermesKit
import os

/// Signposts for Instruments (docs/performance-tracing.md), in the Points of Interest
/// track: HermesKit's spans (`Tracing`: Markdown parse, Transcript grouping, History
/// page, Snapshot rebuild) and the app's own (Math typeset, Chat selected, and a
/// message's Text apply, Text measure and Text draw). Off while nothing records them:
/// a signpost then costs one check.
enum AppSignposts {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "Hermes",
                                         category: .pointsOfInterest)

    /// Reports HermesKit's spans here. Once, at launch.
    static func install() { Tracing.install(Tracer()) }

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        try signposter.withIntervalSignpost(name) { try body() }
    }

    static func event(_ name: StaticString) { signposter.emitEvent(name) }

    /// An interval that ends with `end()`, for work that has no closure of its own:
    /// `let span = AppSignposts.begin("…"); defer { span.end() }`.
    static func begin(_ name: StaticString) -> Span {
        Span(name: name, state: signposter.beginInterval(name))
    }

    struct Span {
        let name: StaticString
        let state: OSSignpostIntervalState
        func end() { AppSignposts.signposter.endInterval(name, state) }
    }

    private struct Tracer: WorkTracer {
        func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
            try AppSignposts.measure(name, body)
        }
    }
}
