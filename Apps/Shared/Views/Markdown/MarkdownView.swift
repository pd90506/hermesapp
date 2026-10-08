import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders Markdown parsed by HermesKit's `MarkdownDocument`; layout only.
struct MarkdownView: View, Equatable {
    let text: String
    /// Still receiving deltas: parse leniently and hold back unclosed math.
    let isStreaming: Bool
    var conversationSource: (() -> String)? = nil
    var isReasoning = false

    @ScaledMetric(relativeTo: .body) private var mathSize = MarkdownMetrics.bodySize

    var body: some View {
        SelectableMarkdownText(selection: MarkdownDocumentCache.selection(for: text, streaming: isStreaming),
                               source: text, bodySize: mathSize * (isReasoning ? 0.92 : 1),
                               isReasoning: isReasoning, conversationSource: conversationSource)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isStreaming == rhs.isStreaming && lhs.text == rhs.text && lhs.isReasoning == rhs.isReasoning
    }
}

/// Finished messages are parsed once and reused when rows scroll back into
/// view. Streaming prefixes are parsed fresh each time and not cached.
@MainActor
private enum MarkdownDocumentCache {
    private final class Entry {
        let selection: MarkdownSelection
        init(_ selection: MarkdownSelection) { self.selection = selection }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()

    static func selection(for text: String, streaming: Bool) -> MarkdownSelection {
        if streaming { return MarkdownSelection(parsing: text, streaming: true) }
        let key = text as NSString
        if let entry = cache.object(forKey: key) { return entry.selection }
        let selection = MarkdownSelection(parsing: text)
        cache.setObject(Entry(selection), forKey: key)
        return selection
    }
}

enum MarkdownMetrics {
    #if os(macOS)
    static let bodySize: CGFloat = 13
    #else
    static let bodySize: CGFloat = 17
    #endif
}

enum Clipboard {
    #if os(macOS)
    @MainActor
    static func copy(_ string: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
    #else
    @MainActor
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }
    #endif
}
