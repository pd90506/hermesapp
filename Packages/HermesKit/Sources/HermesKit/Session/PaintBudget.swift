import Foundation

/// How much of a transcript the chat builds at once when it comes on screen, as
/// Desktop's render budget does (`apps/desktop/src/components/assistant-ui/thread/list.tsx:106-161`):
/// the newest blocks first, about a screen of them, then the older ones above in steps,
/// one per frame. Built all at once, a page of stored rows (`ChatSession.pageSize`) held
/// the main thread for most of a second before the chat showed at all.
///
/// The budget is in characters, roughly what a block costs to set and lay out
/// (`weight(of:)`), not in blocks: a one-line reply and a reply of code and tables are
/// not the same work.
public enum PaintBudget {
    /// The first frame: a little more than a screen of the newest blocks.
    public static let firstPaint = 6_000
    /// What each later frame adds above what is built.
    public static let step = 8_000
    /// The first frame builds at least this many blocks, however heavy.
    public static let minimumBlocks = 4

    /// What `block` costs to build, in characters. A tool run and a reasoning fold are
    /// closed (one line) until opened, so their content costs nothing yet; a line break
    /// counts as a short line (code, lists, tables).
    public static func weight(of block: TranscriptBlock) -> Int {
        switch block {
        case .item(let item):
            guard item.role != .tool else { return 400 }
            var newlines = 0
            for unit in item.text.utf8 where unit == 0x0A { newlines += 1 }
            return 150 + item.text.utf8.count + 60 * newlines
        case .run:
            return 150
        }
    }

    /// Where to start building so that `blocks[start..<end]` weighs at least `budget`
    /// (or holds `minimumBlocks`), walking back from `end`. 0 when everything before
    /// `end` fits.
    public static func start(in blocks: [TranscriptBlock], end: Int, budget: Int, minimumBlocks: Int = 0) -> Int {
        var start = min(max(end, 0), blocks.count)
        var weight = 0
        while start > 0, weight < budget || end - start < minimumBlocks {
            start -= 1
            weight += Self.weight(of: blocks[start])
        }
        return start
    }

    /// The first frame's start: the newest blocks, `firstPaint` of them.
    public static func firstPaintStart(in blocks: [TranscriptBlock]) -> Int {
        start(in: blocks, end: blocks.count, budget: firstPaint, minimumBlocks: minimumBlocks)
    }
}
