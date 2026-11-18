import Foundation
import Synchronization
import Testing

@testable import HermesBridge

@MainActor
@Suite struct BridgeCommandTests {
    @Test func startsWithADisconnectedSnapshot() {
        let outbox = Outbox()
        _ = Bridge(emit: { outbox.append($0) })
        let first = outbox.all.first
        #expect(first?["type"] as? String == "connection")
        #expect(first?["state"] as? String == "disconnected")
        #expect((first?["sessions"] as? [Any])?.isEmpty == true)
    }

    @Test func repliesToEachCommandById() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive(#"{"id":"c1","method":"closeChat"}"#)
        let reply = outbox.all.last
        #expect(reply?["type"] as? String == "reply")
        #expect(reply?["id"] as? String == "c1")
        #expect(reply?["error"] == nil)
    }

    @Test func unknownMethodsAndMissingParametersAreErrors() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive(#"{"id":"c1","method":"nope"}"#)
        #expect(outbox.all.last?["error"] as? String == "unknown method nope")
        await bridge.receive(#"{"id":"c2","method":"openBotChat","params":{}}"#)
        #expect(outbox.all.last?["error"] as? String == "missing profile")
        await bridge.receive(#"{"id":"c3","method":"send","params":{"text":"hi"}}"#)
        #expect(outbox.all.last?["error"] as? String == "no open chat")
    }

    @Test func sessionActionsNeedAListedSession() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        for (n, method) in ["renameSession", "forkSession", "archiveSession", "deleteSession"].enumerated() {
            await bridge.receive(#"{"id":"s\#(n)","method":"\#(method)","params":{"id":"p/x","title":"T"}}"#)
            #expect(outbox.all.last?["error"] as? String == "no session p/x in the list")
        }
    }

    @Test func aProfileWithoutAnAvatarHasNoImage() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive(#"{"id":"a1","method":"avatar","params":{"profile":"p"}}"#)
        #expect(outbox.all.last?["error"] == nil)
        #expect((outbox.all.last?["result"] as? [String: Any])?["data"] is NSNull)
        await bridge.receive(#"{"id":"a2","method":"setAvatar","params":{"profile":"p","data":"!"}}"#)
        #expect(outbox.all.last?["error"] as? String == "data is not base64")
    }

    @Test func aMalformedCommandIsReportedWithoutAnId() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive("not json")
        #expect(outbox.all.last?["type"] as? String == "reply")
        #expect(outbox.all.last?["id"] as? String == "")
        #expect(outbox.all.last?["error"] as? String == "malformed command")
    }

    @Test func aBadUrlFailsTheConnect() async {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive(#"{"id":"c1","method":"connect","params":{"url":"","token":"t"}}"#)
        #expect(outbox.all.last?["id"] as? String == "c1")
        #expect(outbox.all.last?["error"] != nil)
    }
}
