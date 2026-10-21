import Foundation

/// Records named spans of work, for a profiler (the apps: signposts, `AppSignposts`).
/// HermesKit stays Foundation-only, so it only names its work; the app installs the
/// tracer that records it.
public protocol WorkTracer: Sendable {
    func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T
}

/// The installed tracer, if any. Without one, `measure` runs `body` after one short lock.
public enum Tracing {
    private static let state = State()

    /// Installs (or with nil removes) the tracer every later `measure` reports to.
    public static func install(_ tracer: (any WorkTracer)?) {
        state.lock.lock()
        state.tracer = tracer
        state.lock.unlock()
    }

    /// Runs `body` as the span `name`.
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        state.lock.lock()
        let tracer = state.tracer
        state.lock.unlock()
        guard let tracer else { return try body() }
        return try tracer.measure(name, body)
    }

    // `@unchecked Sendable`: `tracer` is only read or written under `lock`.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var tracer: (any WorkTracer)?
    }
}
