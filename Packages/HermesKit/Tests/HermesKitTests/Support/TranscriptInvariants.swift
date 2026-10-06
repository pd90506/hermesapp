import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// The invariants every transcript must keep, whatever arrived in which order:
/// - item ids are unique (`ChatView` renders `ForEach(items)`; a repeated id is undefined
///   behaviour in SwiftUI);
/// - the stored part is in row order, each row at most once;
/// - nothing spins once no turn runs.
func expectWellFormed(_ transcript: Transcript, sourceLocation: SourceLocation = #_sourceLocation) {
    if !transcript.isRunning {
        let active = transcript.items.filter(\.isActive).map(\.id)
        #expect(active.isEmpty, "active items with no turn running: \(active)", sourceLocation: sourceLocation)
    }
    let ids = transcript.items.map(\.id)
    let repeated = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    #expect(repeated.isEmpty, "repeated item ids: \(repeated)", sourceLocation: sourceLocation)
    let rows = transcript.items[..<transcript.historyCount].compactMap(\.rowID)
    #expect(rows == rows.sorted() && Set(rows).count == rows.count,
            "stored rows out of order or repeated: \(rows)", sourceLocation: sourceLocation)
}
