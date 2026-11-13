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

    /// How many unknown commands one formula may show as source before the
    /// whole formula falls back to its LaTeX source.
    private static let maxRevealedCommands = 8

    /// Adds the symbol commands SwiftMath lacks (`LaTeXNormalizer.addedSymbols`)
    /// to its symbol table, once, before the first formula is parsed. Each is
    /// a copy of a built-in symbol of the same class with its character
    /// swapped, so it spaces like one.
    private static let addSymbols: Void = {
        func template(_ kind: LaTeXNormalizer.SymbolKind) -> MTMathAtom? {
            switch kind {
            case .relation: MTMathAtomFactory.atom(forLatexSymbol: "leq")
            case .binary: MTMathAtomFactory.atom(forLatexSymbol: "times")
            case .ordinary: MTMathAtomFactory.atom(forLatexSymbol: "infty")
            case .open: MTMathAtomFactory.atom(forLatexSymbol: "langle")
            case .close: MTMathAtomFactory.atom(forLatexSymbol: "rangle")
            case .punctuation: MTMathAtomFactory.atom(forCharacter: ",")
            }
        }
        for (name, symbol) in LaTeXNormalizer.addedSymbols where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            guard let atom = template(symbol.kind) else { continue }
            atom.nucleus = symbol.character
            MTMathAtomFactory.add(latexSymbol: name, value: atom)
        }
    }()

    private static func typeset(_ latex: String, fontSize: CGFloat, display: Bool) -> Rendered? {
        _ = addSymbols
        var latex = latex
        var revealed = 0
        while true {
            var math = MathImage(latex: latex, fontSize: fontSize, textColor: .black,
                                 labelMode: display ? .display : .text, textAlignment: .left)
            let (error, image, layout) = math.asImage()
            if let error {
                // An unknown command: show just it as source, like KaTeX, and retry.
                guard revealed < maxRevealedCommands,
                      let retry = LaTeXNormalizer.revealingUnknownCommand(latex, parseError: error.localizedDescription)
                else { return nil }
                latex = retry
                revealed += 1
                continue
            }
            return rendered(image, layout, fontSize: fontSize)
        }
    }

    private static func rendered(_ image: MTImage?, _ layout: MathImage.LayoutInfo?, fontSize: CGFloat) -> Rendered? {
        guard let image, let layout, image.size.width > 0 else { return nil }
        // Mirror MathImage's vertical placement to find the baseline.
        let height = max(layout.ascent + layout.descent, fontSize / 2)
        let baseline = (image.size.height - height) / 2 + layout.descent
        return Rendered(image: image, baseline: baseline)
    }
}
