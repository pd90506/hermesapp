import Foundation
import Synchronization
import Testing

@testable import HermesBridge

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
        // The connection snapshot (the bridge also sends empty search and cron ones).
        let connection = outbox.all.first(where: { $0["type"] as? String == "connection" }) ?? [:]
        #expect((connection["sessions"] as? [Any])?.isEmpty == true)
    }
}
