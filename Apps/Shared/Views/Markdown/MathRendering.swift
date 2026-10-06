import HermesKit
import SwiftMath
import SwiftUI

/// Typesets LaTeX with SwiftMath into template images, cached by source and size.
///
/// Images are rendered once in black and marked as templates, so SwiftUI tints
/// them with the current foreground style: math follows light/dark mode and
/// secondary styles without re-rendering. (`\color` is therefore ignored.)
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: Image
        /// Distance from the image's bottom edge up to the math baseline.
        let baseline: CGFloat
    }

    private final class Entry {
        let rendered: Rendered?
        init(_ rendered: Rendered?) { self.rendered = rendered }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 500
        return cache
    }()

    /// The rendered formula, or nil when SwiftMath rejects it.
    static func render(_ latex: String, fontSize: CGFloat, display: Bool) -> Rendered? {
        let key = "\(display ? "D" : "T")\(fontSize)|\(latex)" as NSString
        if let entry = cache.object(forKey: key) { return entry.rendered }
        let rendered = typeset(latex, fontSize: fontSize, display: display)
        cache.setObject(Entry(rendered), forKey: key)
        return rendered
    }

    private static func typeset(_ latex: String, fontSize: CGFloat, display: Bool) -> Rendered? {
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: .black,
                             labelMode: display ? .display : .text, textAlignment: .left)
        let (error, platformImage, layout) = math.asImage()
        guard error == nil, let platformImage, let layout, platformImage.size.width > 0 else { return nil }
        // Mirror MathImage's vertical placement to find the baseline.
        let height = max(layout.ascent + layout.descent, fontSize / 2)
        let baseline = (platformImage.size.height - height) / 2 + layout.descent
        #if os(macOS)
        platformImage.isTemplate = true
        let image = Image(nsImage: platformImage)
        #else
        let image = Image(uiImage: platformImage.withRenderingMode(.alwaysTemplate))
        #endif
        return Rendered(image: image.renderingMode(.template), baseline: baseline)
    }
}

/// A display formula: centered when it fits, horizontally scrollable when not.
/// Unrenderable LaTeX, and a formula still streaming in, show the source.
struct MathBlockView: View {
    let snippet: MathSnippet
    @Environment(\.markdownIsStreaming) private var isStreaming
    @Environment(\.markdownMathSize) private var mathSize

    var body: some View {
        if !snippet.isClosed && isStreaming {
            MathSourceView(source: snippet.source)
        } else if let rendered = MathRenderer.render(snippet.latex, fontSize: mathSize * 1.1, display: true) {
            ViewThatFits(in: .horizontal) {
                rendered.image
                    .frame(maxWidth: .infinity)
                ScrollView(.horizontal) {
                    rendered.image
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityLabel(snippet.source)
            .contextMenu {
                Button("Copy LaTeX", systemImage: "doc.on.doc") { Clipboard.copy(snippet.source) }
            }
        } else {
            MathSourceView(source: snippet.source)
        }
    }
}

/// LaTeX source shown as-is: monospaced and selectable.
struct MathSourceView: View {
    let source: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(source)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize()
                .padding(8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
    }
}
