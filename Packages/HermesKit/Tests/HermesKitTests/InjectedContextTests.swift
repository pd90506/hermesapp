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

    /// A prompt with an attached Markdown file, stored as the gateway expanded it for the
    /// model (`agent/context_references.py:240-246,386`, `tui_gateway/prompt_turn.py:705-722`).
    static let fileTurn = """
    @file:attachments/notes.md

    Summarize this

    --- Attached Context ---

    📄 @file:attachments/notes.md (12 tokens)
    ```markdown
    # Notes
    - @image:not-an-image.png
    - [screenshot]
    ```
    """

    @Test func attachedFilesShowAsFilesNotTheirText() {
        #expect(InjectedContext.userTurn(Self.fileTurn) == ("@file:attachments/notes.md\n\nSummarize this", []))
        // A file-only turn keeps just its reference.
        let fileOnly = "@file:a.md\n\n--- Attached Context ---\n\n📄 @file:a.md (3 tokens)\n```markdown\nhi\n```"
        #expect(InjectedContext.userTurn(fileOnly) == ("@file:a.md", []))
    }

    @Test func contextWarningsAreNotTheUsersText() {
        let warned = "@file:gone.md\n\nread it\n\n--- Context Warnings ---\n- @file:gone.md: file not found"
        #expect(InjectedContext.userTurn(warned) == ("@file:gone.md\n\nread it", []))
        let both = "@file:big.md\nhi\n\n--- Context Warnings ---\n- @ context injection warning: 9 tokens\n\n"
            + "--- Attached Context ---\n\n📄 @file:big.md (9 tokens)\n```markdown\nx\n```"
        #expect(InjectedContext.userTurn(both) == ("@file:big.md\nhi", []))
    }

    @Test func aFileThePromptNoLongerNamesComesBack() {
        // An older gateway took the token out of the prompt; Desktop hoists it (`hydration.ts:137-145`).
        let older = "Summarize this\n\n--- Attached Context ---\n\n📄 @file:notes.md (2 tokens)\n```markdown\nx\n```\n\n"
            + "📁 @folder:src (4 tokens)\nsrc/\n  a.swift"
        #expect(InjectedContext.userTurn(older) == ("@file:notes.md\n@folder:src\n\nSummarize this", []))
        // One typed mid-prose is already there, so it is not listed twice.
        let inline = "Compare @file:a.md\n\n--- Attached Context ---\n\n📄 @file:a.md (1 tokens)\n```\nx\n```"
        #expect(InjectedContext.userTurn(inline) == ("Compare @file:a.md", []))
    }

    @Test func imagesSentWithAFileStay() {
        // `_build_persist_message_with_image_refs` appends the `@image:` lines after the
        // expanded prompt (`tui_gateway/session_history.py:51-60`).
        let turn = Self.fileTurn + "\n@image:/h/images/a.png"
        #expect(InjectedContext.userTurn(turn).text
            == "@file:attachments/notes.md\n\nSummarize this\n@image:/h/images/a.png")
        let hinted = "@file:a.md\n\nlook\n\n--- Attached Context ---\n\n📄 @file:a.md (1 tokens)\n```\nx\n```\n\n"
            + "[Image attached at: /h/a.png]\n[screenshot]"
        #expect(InjectedContext.userTurn(hinted) == ("@file:a.md\n\nlook", ["/h/a.png"]))
    }

    @Test func markersTypedInsideALineStayText() {
        let typed = "Hermes appends --- Attached Context --- to prompts"
        #expect(InjectedContext.userTurn(typed) == (typed, []))
    }

    @Test func storedFileRowsShowTheFileAndThePrompt() {
        var calls: StoredMessageProjection.ToolCalls = [:]
        let rows = [
            StoredMessage(id: 1, role: "user", content: .string(Self.fileTurn + "\n@image:/h/images/a.png")),
        ]
        let items = StoredMessageProjection.items(from: rows, toolCalls: &calls)
        #expect(items.map(\.text) == ["Summarize this"])
        #expect(items.first?.attachments == ["notes.md"])
        #expect(items.first?.attachmentPaths == ["attachments/notes.md"])
        #expect(items.first?.images.map(\.path) == ["/h/images/a.png"])
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
