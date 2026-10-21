import Foundation
import Testing
@testable import HermesKit

/// The spans HermesKit names for the apps' signposts (`Tracing`). Serialized: the tracer
/// is global, so other suites' parsing reports to it too; the checks only look for
/// this suite's spans.
@Suite(.serialized) struct TracingTests {
    final class Recorder: WorkTracer, @unchecked Sendable {
        // `@unchecked Sendable`: `names` is only touched under `lock`.
        private let lock = NSLock()
        private var names: [String] = []
        var spans: [String] {
            lock.lock(); defer { lock.unlock() }
            return names
        }

        func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
            lock.lock()
            names.append("\(name)")
            lock.unlock()
            return try body()
        }
    }

    @Test func markdownParsingAndGroupingAreSpans() {
        let recorder = Recorder()
        Tracing.install(recorder)
        defer { Tracing.install(nil) }
        let document = MarkdownDocument(parsing: "# Title\n\nText")
        #expect(document.blocks.count == 2, "the span returns the parse")
        _ = TranscriptGrouping.blocks([TranscriptItem(id: "u", role: .user, text: "Hi")], isRunning: false)
        #expect(recorder.spans.contains("Markdown parse"))
        #expect(recorder.spans.contains("Transcript grouping"))
    }

    @Test func withoutATracerNothingIsRecorded() {
        let recorder = Recorder()
        Tracing.install(recorder)
        Tracing.install(nil)
        _ = MarkdownDocument(parsing: "Text")
        #expect(recorder.spans.isEmpty)
    }

    @Test func aThrowingSpanRethrows() {
        struct Failure: Error {}
        Tracing.install(Recorder())
        defer { Tracing.install(nil) }
        #expect(throws: Failure.self) { try Tracing.measure("Failing") { throw Failure() } }
    }
}
