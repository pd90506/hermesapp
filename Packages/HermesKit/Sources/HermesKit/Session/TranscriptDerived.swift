import Foundation
import Synchronization

/// What a transcript derives from its rows, kept until the rows change: its blocks
/// (`TranscriptGrouping.blocks`) and its prompts (`PromptMark.marks`).
///
/// The chat reads both each time a block scrolls on or off screen (the prompt rail, the
/// scroll-to-bottom button). Grouped afresh each time, a long chat spent a few percent of
/// a scroll's main thread on it (Instruments, 2026-10-21).
///
/// The rows are kept with what was derived from them. Unchanged rows share their storage,
/// so telling them apart is quick; changed rows are compared once, then derived again.
/// Shared between a transcript's copies, as both hold the same rows until one changes.
final class TranscriptDerived: Sendable {
    private struct Blocks {
        var items: [TranscriptItem]
        var isRunning: Bool
        var blocks: [TranscriptBlock]
    }

    private struct Marks {
        var items: [TranscriptItem]
        var marks: [PromptMark]
    }

    private let blocks = Mutex<Blocks?>(nil)
    private let marks = Mutex<Marks?>(nil)

    func blocks(_ items: [TranscriptItem], isRunning: Bool) -> [TranscriptBlock] {
        if let cached = blocks.withLock({ $0 }), cached.isRunning == isRunning, cached.items == items {
            return cached.blocks
        }
        let derived = TranscriptGrouping.blocks(items, isRunning: isRunning)
        blocks.withLock { $0 = Blocks(items: items, isRunning: isRunning, blocks: derived) }
        return derived
    }

    func marks(_ items: [TranscriptItem]) -> [PromptMark] {
        if let cached = marks.withLock({ $0 }), cached.items == items { return cached.marks }
        let derived = PromptMark.marks(in: items)
        marks.withLock { $0 = Marks(items: items, marks: derived) }
        return derived
    }
}

/// A transcript's `TranscriptDerived`: not part of what it is, so two transcripts with the
/// same rows are equal whatever either has derived.
struct TranscriptDerivedBox: Sendable, Hashable {
    let derived = TranscriptDerived()

    static func == (lhs: Self, rhs: Self) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}
