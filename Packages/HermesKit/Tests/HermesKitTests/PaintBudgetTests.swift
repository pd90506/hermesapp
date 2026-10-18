import HermesKit
import Testing

/// What a chat builds first when it comes on screen, and in what steps the rest.
@Suite struct PaintBudgetTests {
    private func reply(_ id: Int, characters: Int) -> TranscriptBlock {
        .item(TranscriptItem(id: "a\(id)", role: .assistant, text: String(repeating: "x", count: characters)))
    }

    @Test func theFirstFrameIsTheNewestScreen() {
        let blocks = (0..<100).map { reply($0, characters: 1_000) }
        let start = PaintBudget.firstPaintStart(in: blocks)
        let built = blocks[start...].map(PaintBudget.weight(of:)).reduce(0, +)
        #expect(start > 90, "a few blocks, not the page (from \(start))")
        #expect(built >= PaintBudget.firstPaint)
        #expect(built - PaintBudget.weight(of: blocks[start]) < PaintBudget.firstPaint, "no more than it needs")
    }

    @Test func heavyBlocksStillShowAFewInTheFirstFrame() {
        let blocks = (0..<20).map { reply($0, characters: 50_000) }
        #expect(PaintBudget.firstPaintStart(in: blocks) == 20 - PaintBudget.minimumBlocks)
    }

    @Test func aShortChatIsBuiltAtOnce() {
        let blocks = (0..<3).map { reply($0, characters: 200) }
        #expect(PaintBudget.firstPaintStart(in: blocks) == 0)
        #expect(PaintBudget.firstPaintStart(in: []) == 0)
    }

    /// A step adds blocks above what is built, never past the beginning.
    @Test func stepsWalkBackToTheBeginning() {
        let blocks = (0..<120).map { reply($0, characters: 1_500) }
        var start = PaintBudget.firstPaintStart(in: blocks)
        var steps = 0
        while start > 0 {
            let next = PaintBudget.start(in: blocks, end: start, budget: PaintBudget.step)
            #expect(next < start)
            start = next
            steps += 1
        }
        #expect(steps >= 2 && steps < blocks.count / 2, "\(steps) steps")
    }

    /// Line breaks count (code, lists, tables are many short lines); a tool run is one
    /// closed line whatever it holds.
    @Test func weights() {
        let prose = reply(0, characters: 600)
        let code = TranscriptBlock.item(TranscriptItem(id: "c", role: .assistant,
                                                       text: String(repeating: "let x = 1\n", count: 60)))
        #expect(PaintBudget.weight(of: code) > 2 * PaintBudget.weight(of: prose))
        let tools = (0..<30).map { TranscriptItem(id: "t\($0)", role: .tool, text: String(repeating: "y", count: 5_000)) }
        #expect(PaintBudget.weight(of: .run(ToolRun(id: "r", items: tools, isLive: false))) < 500)
    }
}
