import Foundation
import Synchronization
import Testing

@testable import HermesBridge

/// Collects what the bridge emits.
private final class Outbox: Sendable {
    private let events = Mutex<[String]>([])
    func append(_ json: String) { events.withLock { $0.append(json) } }
    var last: [String: Any] {
        events.withLock { $0 }.last.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        } ?? [:]
    }
}

@MainActor
@Suite struct BridgePinTests {
    @Test func pinsComeFromTheAppAndNeedAServerID() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive(#"{"id":"p1","method":"setPins","params":{"server":"nope"}}"#)
        #expect(outbox.last["error"] as? String == "server is not a UUID")
        await bridge.receive(#"{"id":"p2","method":"setPins","params":{"server":"6F9619FF-8B86-D011-B42D-00C04FC964FF","pins":{"keys":[]}}}"#)
        #expect(outbox.last["id"] as? String == "p2")
        #expect(outbox.last["error"] == nil)
        // An app with none saved yet sends null.
        await bridge.receive(#"{"id":"p3","method":"setPins","params":{"server":"6F9619FF-8B86-D011-B42D-00C04FC964FF","pins":null}}"#)
        #expect(outbox.last["id"] as? String == "p3")
        #expect(outbox.last["error"] == nil)
    }

    @Test func onlyAListedSessionCanBePinned() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive(#"{"id":"p1","method":"pinSession","params":{"id":"default/abc","pinned":true}}"#)
        #expect(outbox.last["error"] as? String == "no session default/abc in the list")
    }

    @Test func anEmptyListHasNoGroups() {
        let outbox = Outbox()
        _ = Bridge(emit: { outbox.append($0) })
        #expect((outbox.last["sessions"] as? [Any])?.isEmpty == true)
    }
}
