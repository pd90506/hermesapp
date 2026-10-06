import Foundation

/// Combines a draft the app changed while an input method was composing in the text
/// view (a failed prompt's text given back, `ChatComposer.restoreText`) with what the
/// user composed meanwhile. The text view leaves the composition alone and calls this
/// once the composition ends.
///
/// A three-way merge in UTF-16 units (the text views' own units): `base` is the draft
/// as the text view last left it, `theirs` the app's new draft, `mine` the text view's
/// text. Each side changed one stretch of `base`; when the two stretches don't overlap,
/// both changes are kept. When they do (the draft was cleared by a send, or replaced),
/// the app's draft wins: given-back text is never dropped.
public enum DraftMerge {
    /// - Returns: the merged text, and the caret (a UTF-16 offset) just after the
    ///   user's own change.
    public static func merge(base: String, theirs: String, mine: String) -> (text: String, caret: Int) {
        let base = Array(base.utf16), theirs = Array(theirs.utf16), mine = Array(mine.utf16)
        let their = changed(base, theirs), my = changed(base, mine)
        let merged: [UInt16]
        let caret: Int
        if their.end <= my.start {
            // The app's change comes first: its side up to there, then the user's.
            let head = theirs[..<(theirs.count - (base.count - their.end))]
            merged = Array(head) + base[their.end..<my.start] + mine[my.start...]
            caret = merged.count - (base.count - my.end)
        } else if my.end <= their.start {
            let head = mine[..<(mine.count - (base.count - my.end))]
            merged = Array(head) + base[my.end..<their.start] + theirs[their.start...]
            caret = head.count
        } else {
            return (String(decoding: theirs, as: UTF16.self), theirs.count)
        }
        return (String(decoding: merged, as: UTF16.self), caret)
    }

    /// The stretch `start..<end` of `old` that `new` replaced: what is left after their
    /// common prefix and common suffix.
    private static func changed(_ old: [UInt16], _ new: [UInt16]) -> (start: Int, end: Int) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        return (prefix, old.count - suffix)
    }
}
