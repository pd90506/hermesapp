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
        VStack(alignment: .leading, spacing: MarkdownLayout.blockGap) {
            ForEach(MarkdownDocumentCache.presentation(for: text, streaming: isStreaming).parts) { part in
                switch part.content {
                case .prose(let selection):
                    SelectableMarkdownText(selection: selection, source: text,
                                           bodySize: mathSize * (isReasoning ? 0.92 : 1),
                                           isReasoning: isReasoning, conversationSource: conversationSource)
                case .code(let language, let code, _):
                    MarkdownCodeBlock(language: language, code: code,
                                      messageSource: text, conversationSource: conversationSource)
                case .table(let table):
                    MarkdownTableGrid(table: table, messageSource: text,
                                      conversationSource: conversationSource)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let presentation: MarkdownPresentation
        init(_ presentation: MarkdownPresentation) { self.presentation = presentation }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()

    static func presentation(for text: String, streaming: Bool) -> MarkdownPresentation {
        if streaming { return MarkdownPresentation(parsing: text, streaming: true) }
        let key = text as NSString
        if let entry = cache.object(forKey: key) { return entry.presentation }
        let presentation = MarkdownPresentation(parsing: text)
        cache.setObject(Entry(presentation), forKey: key)
        return presentation
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
