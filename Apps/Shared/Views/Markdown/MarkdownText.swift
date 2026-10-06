import HermesKit
import SwiftUI

extension EnvironmentValues {
    /// The message is still streaming: unclosed display math shows its source.
    @Entry var markdownIsStreaming = false
    /// Point size for math in body text; scaled with Dynamic Type by `MarkdownView`.
    @Entry var markdownMathSize: CGFloat = MarkdownMetrics.bodySize
    @Entry var markdownListDepth = 0
}

enum MarkdownMetrics {
    #if os(macOS)
    static let bodySize: CGFloat = 13
    #else
    static let bodySize: CGFloat = 17
    #endif
}

/// One run of inline Markdown as a single `Text`, so it wraps and selects as
/// text. Inline math is embedded as a baseline-aligned image; math SwiftMath
/// rejects falls back to its source in code style.
struct InlineText: View {
    let content: [MarkdownInline]
    /// Math size relative to body text (headings render larger).
    var mathScale: CGFloat = 1
    @Environment(\.markdownMathSize) private var mathSize

    var body: some View {
        Self.text(content, mathSize: mathSize * mathScale)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func text(_ content: [MarkdownInline], mathSize: CGFloat) -> Text {
        var builder = Builder(mathSize: mathSize)
        builder.append(content, intent: [], link: nil)
        return builder.finish()
    }

    @MainActor
    private struct Builder {
        let mathSize: CGFloat
        var pieces: [Text] = []
        var run = AttributedString()

        init(mathSize: CGFloat) { self.mathSize = mathSize }

        mutating func append(_ content: [MarkdownInline], intent: InlinePresentationIntent, link: URL?) {
            for inline in content {
                switch inline {
                case .text(let text): appendRun(text, intent: intent, link: link)
                case .code(let code): appendRun(code, intent: intent.union(.code), link: link)
                case .emphasis(let children): append(children, intent: intent.union(.emphasized), link: link)
                case .strong(let children): append(children, intent: intent.union(.stronglyEmphasized), link: link)
                case .strikethrough(let children): append(children, intent: intent.union(.strikethrough), link: link)
                case .link(let destination, let children): append(children, intent: intent, link: Self.url(destination) ?? link)
                case .lineBreak: appendRun("\n", intent: [], link: nil)
                case .math(let snippet): appendMath(snippet, intent: intent, link: link)
                }
            }
        }

        private mutating func appendRun(_ string: String, intent: InlinePresentationIntent, link: URL?) {
            var piece = AttributedString(string)
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            piece.link = link
            run += piece
        }

        private mutating func appendMath(_ snippet: MathSnippet, intent: InlinePresentationIntent, link: URL?) {
            let size = snippet.isDisplay ? mathSize * 1.1 : mathSize
            guard let rendered = MathRenderer.render(snippet.latex, fontSize: size, display: snippet.isDisplay) else {
                appendRun(snippet.source, intent: intent.union(.code), link: link)
                return
            }
            flushRun()
            pieces.append(Text(rendered.image).baselineOffset(-rendered.baseline).accessibilityLabel(snippet.source))
        }

        private mutating func flushRun() {
            guard !run.characters.isEmpty else { return }
            pieces.append(Text(run))
            run = AttributedString()
        }

        mutating func finish() -> Text {
            flushRun()
            if pieces.count == 1 { return pieces[0] }
            // Interpolation rather than `Text + Text`, which the 26 SDKs deprecate.
            var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: pieces.count)
            for piece in pieces { interpolation.appendInterpolation(piece) }
            return Text(LocalizedStringKey(stringInterpolation: interpolation))
        }

        /// Only web and mail links are tappable.
        private static func url(_ destination: String) -> URL? {
            guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return nil }
            return url
        }
    }
}
