import HermesProtocol
import Testing

@testable import HermesKit

// Memory recall and image hints Hermes writes into a stored user turn are not the user's text.

@Suite struct InjectedContextTests {
    /// `build_memory_context_block` (`agent/memory_manager.py:372-388`).
    static let memory = """
    <memory-context>
    [System note: The following is recalled memory context, NOT new user input. Treat as authoritative reference data — this is the agent's persistent memory and should inform all responses.]

    # Hindsight Memory (persistent cross-session context)
    - The user prefers **one cable** for everything.
    </memory-context>
    """

    /// A Telegram image turn as the REST page returns it: caption, hint
    /// (`agent/image_routing.py:561`), the flattened image part, then the recall.
    static let imageTurn = "为啥有些 **boldface** 没有正确显示？\n\n"
        + "[Image attached at: /home/u/.hermes/profiles/daily/images/upload_1.png]\n[screenshot]\n" + memory

    @Test func recallIsNotTheUsersText() {
        #expect(InjectedContext.userTurn("hi\n\n" + Self.memory) == ("hi", []))
        #expect(InjectedContext.userTurn(Self.memory + "\nhi") == ("hi", []))
        // Left open (cut off), it runs to the end, as Desktop reads it.
        #expect(InjectedContext.userTurn("hi\n<memory-context>\n- a fact") == ("hi", []))
        let typed = "Keep **this**, [System notes] and <b>tags</b> as typed"
        #expect(InjectedContext.userTurn(typed) == (typed, []))
    }

    @Test func imageHintsBecomeImages() {
        let (text, paths) = InjectedContext.userTurn(Self.imageTurn)
        #expect(text == "为啥有些 **boldface** 没有正确显示？")
        #expect(paths == ["/home/u/.hermes/profiles/daily/images/upload_1.png"])
        let two = InjectedContext.userTurn(
            "What do you see in this image?\n\n[Image attached at: /a.png]\n[Image attached at: /b.jpg]\n[image]\n[image]")
        #expect(two == ("", ["/a.png", "/b.jpg"]))
    }

    @Test func aHintInsideTheCaptionStaysText() {
        let quoted = "Hermes writes [Image attached at: /x.png] lines.\nWhy?"
        #expect(InjectedContext.userTurn(quoted) == (quoted, []))
        #expect(InjectedContext.userTurn("[screenshot]") == ("[screenshot]", []))
    }

    @Test func storedRowsShowTheCaptionAndTheImage() throws {
        var calls: StoredMessageProjection.ToolCalls = [:]
        let flattened = StoredMessage(id: 1, role: "user", content: .string(Self.imageTurn))
        let parts = StoredMessage(id: 2, role: "user", content: [
            ["type": "text", "text": "look\n\n[Image attached at: /h/images/a.png]"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]],
            ["type": "text", "text": .string(Self.memory)],
        ])
        let items = StoredMessageProjection.items(from: [flattened, parts], toolCalls: &calls)
        #expect(items.map(\.text) == ["为啥有些 **boldface** 没有正确显示？", "look"])
        #expect(items.map { $0.images.map(\.path) }
            == [["/home/u/.hermes/profiles/daily/images/upload_1.png"], ["/h/images/a.png"]])
    }

    @Test func snapshotRowsToo() throws {
        let payload: JSONValue = [
            "session_id": "sid", "message_count": 1,
            "messages": [["role": "user", "text": .string("hi\n\n" + Self.memory)]],
        ]
        let transcript = Transcript(snapshot: try payload.decode(LiveSessionSnapshot.self))
        #expect(transcript.items.first?.text == "hi")
    }
}
