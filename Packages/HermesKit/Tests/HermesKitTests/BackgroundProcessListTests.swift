import Foundation
import HermesProtocol
import Testing
@testable import HermesKit

/// A `process.list` row (`tools/process_registry.py:2393-2420`, `tui_gateway/server.py:2068`).
private func row(_ id: String, command: String = "sleep 60", status: String = "running",
                 exitCode: Int? = nil) -> JSONValue {
    var row: [String: JSONValue] = ["session_id": .string(id), "command": .string(command), "status": .string(status)]
    if let exitCode { row["exit_code"] = .number(Double(exitCode)) }
    return .object(row)
}

struct BackgroundProcessListTests {
    @Test func rowsKeepTheirPlaceAndNewOnesGoLast() {
        var list = BackgroundProcessList()
        list.reconcile([row("a"), row("b")])
        list.reconcile([row("c"), row("b"), row("a")])
        #expect(list.processes.map(\.id) == ["a", "b", "c"])
    }

    @Test func aFinishReportsOnceWithItsState() {
        var list = BackgroundProcessList()
        list.reconcile([row("ok"), row("bad")])
        let finished = list.reconcile([row("ok", status: "exited", exitCode: 0), row("bad", status: "exited", exitCode: 2)])
        #expect(finished.map(\.state) == [.done, .failed])
        #expect(list.reconcile([row("ok", status: "exited", exitCode: 0)]).isEmpty)
    }

    /// One first seen already finished was never running here: no notification.
    @Test func aProcessFirstSeenFinishedIsNotReported() {
        var list = BackgroundProcessList()
        #expect(list.reconcile([row("x", status: "exited", exitCode: 0)]).isEmpty)
        #expect(list.running.isEmpty)
    }

    @Test func aDismissedRowStaysGoneWhileListed() {
        var list = BackgroundProcessList()
        list.reconcile([row("a", status: "exited", exitCode: 0)])
        list.dismiss("a")
        list.reconcile([row("a", status: "exited", exitCode: 0)])
        #expect(list.processes.isEmpty)
    }

    @Test func titleIsTheCommandsFirstLine() {
        #expect(BackgroundProcess(row: row("a", command: "  make\nmore"))?.title == "make")
        #expect(BackgroundProcess(row: row("a", command: ""))?.title == "background process")
    }

    @Test func statusPutsAQuestionFirst() {
        #expect(ChatStatus.resolve(waiting: true, running: true, background: true) == .waitingForYou)
        #expect(ChatStatus.resolve(waiting: false, running: true, background: true) == .working)
        #expect(ChatStatus.resolve(waiting: false, running: false, background: true) == .background)
        #expect(ChatStatus.resolve(waiting: false, running: false, background: false) == .idle)
    }
}
