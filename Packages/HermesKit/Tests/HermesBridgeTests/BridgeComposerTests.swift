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
@Suite struct BridgeComposerTests {
    private func reply(_ json: String) async -> [String: Any] {
        let outbox = Outbox()
        let bridge = Bridge(emit: { outbox.append($0) })
        await bridge.receive(json)
        return outbox.last
    }

    @Test func composerCommandsNeedAnOpenChat() async {
        for method in ["reloadModels", "confirmModelSwitch", "cancelModelSwitch", "dismissComposerError"] {
            #expect(await reply(#"{"id":"c","method":"\#(method)"}"#)["error"] as? String == "no open chat")
        }
        #expect(await reply(#"{"id":"c","method":"selectModel","params":{"provider":"p","model":"m"}}"#)["error"]
            as? String == "no open chat")
        #expect(await reply(#"{"id":"c","method":"attachFile","params":{"path":"C:/x.png"}}"#)["error"]
            as? String == "no open chat")
        #expect(await reply(#"{"id":"c","method":"removeAttachment","params":{"id":"x"}}"#)["error"]
            as? String == "no attachment x")
    }

    @Test func aPasteOfTextStaysText() async {
        let result = await reply(#"{"id":"c","method":"decidePaste","params":{"types":["public.utf8-plain-text"],"string":"hello\nworld"}}"#)["result"] as? [String: Any]
        #expect(result?["decision"] as? String == "text")
    }

    @Test func aPastedImageWithItsLinkIsAttached() async {
        let result = await reply(#"{"id":"c","method":"decidePaste","params":{"types":["public.png","public.utf8-plain-text"],"string":"https://example.com/a.png"}}"#)["result"] as? [String: Any]
        #expect(result?["decision"] as? String == "imageData")
        #expect(result?["type"] as? String == "public.png")
    }

    @Test func copiedFilesAreAttachedByTheirPaths() async {
        let result = await reply(#"{"id":"c","method":"decidePaste","params":{"types":[],"files":["C:\\Users\\me\\a.pdf"]}}"#)["result"] as? [String: Any]
        #expect(result?["decision"] as? String == "files")
        #expect(result?["files"] as? [String] == [#"C:\Users\me\a.pdf"#])
    }

    @Test func aFolderIsRefusedBeforeItIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.path
        #expect(throws: BridgeError.self) { try AttachmentFile.load(path: folder) }
    }
}
