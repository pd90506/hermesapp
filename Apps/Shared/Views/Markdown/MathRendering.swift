import HermesKit
import SwiftMath
import SwiftUI

/// Typesets LaTeX with SwiftMath into images, cached by source and size.
///
/// Images are rendered once in black and used as alpha masks: the text host
/// fills them with the surrounding text colour when it draws, so math follows
/// light/dark mode and the secondary style without re-rendering. (`\color` is
/// therefore ignored.)
@MainActor
enum MathRenderer {
    struct Rendered {
        #if os(macOS)
        let image: NSImage
        #else
        let image: UIImage
        #endif
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
        let rendered = AppSignposts.measure("Math typeset") { typeset(latex, fontSize: fontSize, display: display) }
        cache.setObject(Entry(rendered), forKey: key)
        return rendered
    }

    private static func typeset(_ latex: String, fontSize: CGFloat, display: Bool) -> Rendered? {
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: .black,
                             labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, let layout, image.size.width > 0 else { return nil }
        // Mirror MathImage's vertical placement to find the baseline.
        let height = max(layout.ascent + layout.descent, fontSize / 2)
        let baseline = (image.size.height - height) / 2 + layout.descent
        return Rendered(image: image, baseline: baseline)
    }
}
