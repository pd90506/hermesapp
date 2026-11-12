extension LaTeXNormalizer {
    /// How a symbol the apps add to SwiftMath spaces itself, as TeX's atom classes.
    public enum SymbolKind: Sendable, Equatable {
        case relation, binary, ordinary, open, close, punctuation
    }

    public struct AddedSymbol: Sendable, Equatable {
        public let character: String
        public let kind: SymbolKind

        init(_ character: String, _ kind: SymbolKind) {
            self.character = character
            self.kind = kind
        }
    }

    /// Symbol commands that SwiftMath 1.7.3 lacks, which the apps register
    /// with it (`MTMathAtomFactory.add(latexSymbol:value:)`) before the first
    /// formula is typeset. Each has the character and class KaTeX gives it
    /// (`katex` 0.19, which Hermes Desktop renders math with), except
    /// `\ncong`, which is ≇ as in amssymb, and a few names the normalizer
    /// itself emits for negations (`\notni`, `\nsubset`, `\nsupset`,
    /// `\nequiv`, `\napprox`) or used to map to Unicode (`\oiint`,
    /// `\coloneqq`, `\llbracket`, `\rrbracket`).
    ///
    /// They are registered rather than rewritten to Unicode because SwiftMath's
    /// parser silently drops any character outside ASCII (bar Cyrillic and a
    /// few accented letters) in math mode.
    ///
    /// Generated on the Mac by probing every `defineSymbol(math, …)` entry of
    /// KaTeX against SwiftMath 1.7.3 and the character map of Latin Modern
    /// Math, the apps' math font: only commands the parser rejects and
    /// characters the font has are listed. Accents, large operators and
    /// spacing commands are left out, since as a plain symbol they would lose
    /// their placement, limits or width; so is `\And` (`&`, a column separator
    /// here). Unknown commands that remain are shown as source
    /// (`revealingUnknownCommand`).
    public static let addedSymbols: [String: AddedSymbol] = [
        // relation
        "approxeq": .init("≊", .relation), "backepsilon": .init("∍", .relation),
        "backsim": .init("∽", .relation), "backsimeq": .init("⋍", .relation),
        "because": .init("∵", .relation), "between": .init("≬", .relation),
        "blacktriangleleft": .init("◀", .relation), "blacktriangleright": .init("▶", .relation),
        "bowtie": .init("⋈", .relation), "Bumpeq": .init("≎", .relation),
        "bumpeq": .init("≏", .relation), "circeq": .init("≗", .relation),
        "circlearrowleft": .init("↺", .relation), "circlearrowright": .init("↻", .relation),
        "coloneqq": .init("≔", .relation), "curlyeqprec": .init("⋞", .relation),
        "curlyeqsucc": .init("⋟", .relation), "curvearrowleft": .init("↶", .relation),
        "curvearrowright": .init("↷", .relation), "dashv": .init("⊣", .relation),
        "Doteq": .init("≑", .relation), "doteqdot": .init("≑", .relation),
        "downdownarrows": .init("⇊", .relation), "downharpoonleft": .init("⇃", .relation),
        "downharpoonright": .init("⇂", .relation), "eqcirc": .init("≖", .relation),
        "eqsim": .init("≂", .relation), "eqslantgtr": .init("⪖", .relation),
        "eqslantless": .init("⪕", .relation), "fallingdotseq": .init("≒", .relation),
        "frown": .init("⌢", .relation), "geqq": .init("≧", .relation),
        "geqslant": .init("⩾", .relation), "ggg": .init("⋙", .relation),
        "gggtr": .init("⋙", .relation), "gnapprox": .init("⪊", .relation),
        "gneq": .init("⪈", .relation), "gneqq": .init("≩", .relation),
        "gnsim": .init("⋧", .relation), "gt": .init(">", .relation),
        "gtrapprox": .init("⪆", .relation), "gtreqless": .init("⋛", .relation),
        "gtreqqless": .init("⪌", .relation), "gtrless": .init("≷", .relation),
        "gtrsim": .init("≳", .relation), "hookleftarrow": .init("↩", .relation),
        "hookrightarrow": .init("↪", .relation), "imageof": .init("⊷", .relation),
        "Join": .init("⋈", .relation), "leadsto": .init("⇝", .relation),
        "leftarrowtail": .init("↢", .relation), "leftharpoondown": .init("↽", .relation),
        "leftharpoonup": .init("↼", .relation), "leftleftarrows": .init("⇇", .relation),
        "leftrightarrows": .init("⇆", .relation), "leftrightharpoons": .init("⇋", .relation),
        "leftrightsquigarrow": .init("↭", .relation), "leqq": .init("≦", .relation),
        "leqslant": .init("⩽", .relation), "lessapprox": .init("⪅", .relation),
        "lesseqgtr": .init("⋚", .relation), "lesseqqgtr": .init("⪋", .relation),
        "lessgtr": .init("≶", .relation), "lesssim": .init("≲", .relation),
        "Lleftarrow": .init("⇚", .relation), "lll": .init("⋘", .relation),
        "llless": .init("⋘", .relation), "lnapprox": .init("⪉", .relation),
        "lneq": .init("⪇", .relation), "lneqq": .init("≨", .relation),
        "lnsim": .init("⋦", .relation), "longmapsto": .init("⟼", .relation),
        "looparrowleft": .init("↫", .relation), "looparrowright": .init("↬", .relation),
        "Lsh": .init("↰", .relation), "lt": .init("<", .relation),
        "multimap": .init("⊸", .relation), "napprox": .init("≉", .relation),
        "ncong": .init("≇", .relation), "nequiv": .init("≢", .relation),
        "ngeq": .init("≱", .relation), "ngtr": .init("≯", .relation),
        "nLeftarrow": .init("⇍", .relation), "nleftarrow": .init("↚", .relation),
        "nLeftrightarrow": .init("⇎", .relation), "nleftrightarrow": .init("↮", .relation),
        "nleq": .init("≰", .relation), "nless": .init("≮", .relation),
        "nmid": .init("∤", .relation), "notni": .init("∌", .relation),
        "nparallel": .init("∦", .relation), "nprec": .init("⊀", .relation),
        "npreceq": .init("⋠", .relation), "nRightarrow": .init("⇏", .relation),
        "nrightarrow": .init("↛", .relation), "nsim": .init("≁", .relation),
        "nsubset": .init("⊄", .relation), "nsubseteq": .init("⊈", .relation),
        "nsucc": .init("⊁", .relation), "nsucceq": .init("⋡", .relation),
        "nsupset": .init("⊅", .relation), "nsupseteq": .init("⊉", .relation),
        "ntriangleleft": .init("⋪", .relation), "ntrianglelefteq": .init("⋬", .relation),
        "ntriangleright": .init("⋫", .relation), "ntrianglerighteq": .init("⋭", .relation),
        "nVDash": .init("⊯", .relation), "nVdash": .init("⊮", .relation),
        "nvDash": .init("⊭", .relation), "nvdash": .init("⊬", .relation),
        "origof": .init("⊶", .relation), "owns": .init("∋", .relation),
        "preccurlyeq": .init("≼", .relation), "preceq": .init("⪯", .relation),
        "precnsim": .init("⋨", .relation), "precsim": .init("≾", .relation),
        "restriction": .init("↾", .relation), "rightarrowtail": .init("↣", .relation),
        "rightharpoondown": .init("⇁", .relation), "rightharpoonup": .init("⇀", .relation),
        "rightleftarrows": .init("⇄", .relation), "rightleftharpoons": .init("⇌", .relation),
        "rightrightarrows": .init("⇉", .relation), "rightsquigarrow": .init("⇝", .relation),
        "risingdotseq": .init("≓", .relation), "Rrightarrow": .init("⇛", .relation),
        "Rsh": .init("↱", .relation), "shortmid": .init("∣", .relation),
        "shortparallel": .init("∥", .relation), "smallfrown": .init("⌢", .relation),
        "smallsmile": .init("⌣", .relation), "smile": .init("⌣", .relation),
        "Subset": .init("⋐", .relation), "subsetneq": .init("⊊", .relation),
        "succcurlyeq": .init("≽", .relation), "succeq": .init("⪰", .relation),
        "succnsim": .init("⋩", .relation), "succsim": .init("≿", .relation),
        "Supset": .init("⋑", .relation), "supsetneq": .init("⊋", .relation),
        "therefore": .init("∴", .relation), "thickapprox": .init("≈", .relation),
        "thicksim": .init("∼", .relation), "trianglelefteq": .init("⊴", .relation),
        "triangleq": .init("≜", .relation), "trianglerighteq": .init("⊵", .relation),
        "twoheadleftarrow": .init("↞", .relation), "twoheadrightarrow": .init("↠", .relation),
        "upharpoonleft": .init("↿", .relation), "upharpoonright": .init("↾", .relation),
        "upuparrows": .init("⇈", .relation), "varpropto": .init("∝", .relation),
        "vartriangle": .init("△", .relation), "vartriangleleft": .init("⊲", .relation),
        "vartriangleright": .init("⊳", .relation), "Vdash": .init("⊩", .relation),
        "vDash": .init("⊨", .relation), "vdash": .init("⊢", .relation),
        "Vvdash": .init("⊪", .relation),
        // binary
        "barwedge": .init("⊼", .binary), "bigcirc": .init("◯", .binary),
        "bigtriangledown": .init("▽", .binary), "bigtriangleup": .init("△", .binary),
        "boxdot": .init("⊡", .binary), "boxminus": .init("⊟", .binary),
        "boxplus": .init("⊞", .binary), "boxtimes": .init("⊠", .binary), "Cap": .init("⋒", .binary),
        "centerdot": .init("⋅", .binary), "circledast": .init("⊛", .binary),
        "circledcirc": .init("⊚", .binary), "circleddash": .init("⊝", .binary),
        "Cup": .init("⋓", .binary), "curlyvee": .init("⋎", .binary),
        "curlywedge": .init("⋏", .binary), "diamond": .init("⋄", .binary),
        "divideontimes": .init("⋇", .binary), "dotplus": .init("∔", .binary),
        "doublecap": .init("⋒", .binary), "doublecup": .init("⋓", .binary),
        "gtrdot": .init("⋗", .binary), "intercal": .init("⊺", .binary),
        "leftthreetimes": .init("⋋", .binary), "lessdot": .init("⋖", .binary),
        "lhd": .init("⊲", .binary), "ltimes": .init("⋉", .binary), "rhd": .init("⊳", .binary),
        "rightthreetimes": .init("⋌", .binary), "rtimes": .init("⋊", .binary),
        "smallsetminus": .init("∖", .binary), "unlhd": .init("⊴", .binary),
        "unrhd": .init("⊵", .binary), "veebar": .init("⊻", .binary),
        // ordinary
        "backprime": .init("‵", .ordinary), "beth": .init("ℶ", .ordinary),
        "blacksquare": .init("■", .ordinary), "blacktriangle": .init("▲", .ordinary),
        "blacktriangledown": .init("▼", .ordinary), "Box": .init("□", .ordinary),
        "checkmark": .init("✓", .ordinary), "circledR": .init("®", .ordinary),
        "clubsuit": .init("♣", .ordinary), "complement": .init("∁", .ordinary),
        "dag": .init("†", .ordinary), "daleth": .init("ℸ", .ordinary),
        "ddag": .init("‡", .ordinary), "Diamond": .init("◊", .ordinary),
        "diamondsuit": .init("♢", .ordinary), "eth": .init("ð", .ordinary),
        "flat": .init("♭", .ordinary), "gimel": .init("ℷ", .ordinary),
        "heartsuit": .init("♡", .ordinary), "hslash": .init("ℏ", .ordinary),
        "lozenge": .init("◊", .ordinary), "maltese": .init("✠", .ordinary),
        "mathsterling": .init("£", .ordinary), "measuredangle": .init("∡", .ordinary),
        "natural": .init("♮", .ordinary), "nexists": .init("∄", .ordinary),
        "oiint": .init("∯", .ordinary), "P": .init("¶", .ordinary), "pounds": .init("£", .ordinary),
        "S": .init("§", .ordinary), "sharp": .init("♯", .ordinary),
        "spadesuit": .init("♠", .ordinary), "sphericalangle": .init("∢", .ordinary),
        "surd": .init("√", .ordinary), "triangledown": .init("▽", .ordinary),
        "varkappa": .init("ϰ", .ordinary), "varnothing": .init("∅", .ordinary),
        "varvdots": .init("⋮", .ordinary), "yen": .init("¥", .ordinary),
        // open
        "lbrack": .init("[", .open), "llbracket": .init("⟦", .open), "lparen": .init("(", .open),
        "lVert": .init("∥", .open), "lvert": .init("∣", .open),
        // close
        "rbrack": .init("]", .close), "rparen": .init(")", .close), "rrbracket": .init("⟧", .close),
        "rVert": .init("∥", .close), "rvert": .init("∣", .close),
        // punctuation
        "ldotp": .init(".", .punctuation),
    ]

    /// Unicode characters a model may write straight into math (`α ≤ β`, `x ∈ ℝ`),
    /// mapped to a command SwiftMath knows or that `addedSymbols` adds:
    /// SwiftMath would drop the character. From the same KaTeX table, so the
    /// apps accept the characters Hermes Desktop does; a command SwiftMath has
    /// natively is preferred.
    static let unicodeCommands: [Character: String] = [
        "£": "pounds", "¥": "yen", "§": "S", "¬": "neg", "®": "circledR", "°": "degree", "±": "pm",
        "¶": "P", "×": "times", "ð": "eth", "÷": "div", "Γ": "Gamma", "Δ": "Delta", "Θ": "Theta",
        "Λ": "Lambda", "Ξ": "Xi", "Π": "Pi", "Σ": "Sigma", "Υ": "Upsilon", "Φ": "Phi", "Ψ": "Psi",
        "Ω": "Omega", "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "ε": "varepsilon",
        "ζ": "zeta", "η": "eta", "θ": "theta", "ι": "iota", "κ": "kappa", "λ": "lambda", "μ": "mu",
        "ν": "nu", "ξ": "xi", "ο": "omicron", "π": "pi", "ρ": "rho", "ς": "varsigma", "σ": "sigma",
        "τ": "tau", "υ": "upsilon", "φ": "varphi", "χ": "chi", "ψ": "psi", "ω": "omega",
        "ϑ": "vartheta", "ϕ": "phi", "ϖ": "varpi", "ϰ": "varkappa", "ϱ": "varrho", "ϵ": "epsilon",
        "†": "dagger", "‡": "ddagger", "…": "ldots", "′": "prime", "‵": "backprime", "ℏ": "hbar",
        "ℑ": "Im", "ℓ": "ell", "℘": "wp", "ℜ": "Re", "℧": "mho", "ℵ": "aleph", "ℶ": "beth",
        "ℷ": "gimel", "ℸ": "daleth", "←": "gets", "↑": "uparrow", "→": "rightarrow",
        "↓": "downarrow", "↔": "leftrightarrow", "↕": "updownarrow", "↖": "nwarrow", "↗": "nearrow",
        "↘": "searrow", "↙": "swarrow", "↚": "nleftarrow", "↛": "nrightarrow",
        "↞": "twoheadleftarrow", "↠": "twoheadrightarrow", "↢": "leftarrowtail",
        "↣": "rightarrowtail", "↦": "mapsto", "↩": "hookleftarrow", "↪": "hookrightarrow",
        "↫": "looparrowleft", "↬": "looparrowright", "↭": "leftrightsquigarrow",
        "↮": "nleftrightarrow", "↰": "Lsh", "↱": "Rsh", "↶": "curvearrowleft",
        "↷": "curvearrowright", "↺": "circlearrowleft", "↻": "circlearrowright",
        "↼": "leftharpoonup", "↽": "leftharpoondown", "↾": "upharpoonright", "↿": "upharpoonleft",
        "⇀": "rightharpoonup", "⇁": "rightharpoondown", "⇂": "downharpoonright",
        "⇃": "downharpoonleft", "⇄": "rightleftarrows", "⇆": "leftrightarrows",
        "⇇": "leftleftarrows", "⇈": "upuparrows", "⇉": "rightrightarrows", "⇊": "downdownarrows",
        "⇋": "leftrightharpoons", "⇌": "rightleftharpoons", "⇍": "nLeftarrow",
        "⇎": "nLeftrightarrow", "⇏": "nRightarrow", "⇐": "Leftarrow", "⇑": "Uparrow",
        "⇒": "Rightarrow", "⇓": "Downarrow", "⇔": "Leftrightarrow", "⇕": "Updownarrow",
        "⇚": "Lleftarrow", "⇛": "Rrightarrow", "⇝": "rightsquigarrow", "∀": "forall",
        "∁": "complement", "∂": "partial", "∃": "exists", "∄": "nexists", "∅": "emptyset",
        "∇": "nabla", "∈": "in", "∉": "notin", "∋": "ni", "∌": "notni", "∍": "backepsilon",
        "∏": "prod", "∐": "coprod", "∑": "sum", "∓": "mp", "∔": "dotplus", "∖": "setminus",
        "∗": "ast", "∘": "circ", "∙": "bullet", "√": "surd", "∝": "propto", "∞": "infty",
        "∠": "angle", "∡": "measuredangle", "∢": "sphericalangle", "∣": "mid", "∤": "nmid",
        "∥": "parallel", "∦": "nparallel", "∧": "land", "∨": "lor", "∩": "cap", "∪": "cup",
        "∫": "int", "∮": "oint", "∯": "oiint", "∴": "therefore", "∵": "because", "∼": "sim",
        "∽": "backsim", "≀": "wr", "≁": "nsim", "≂": "eqsim", "≃": "simeq", "≅": "cong",
        "≇": "ncong", "≈": "approx", "≉": "napprox", "≊": "approxeq", "≍": "asymp", "≎": "Bumpeq",
        "≏": "bumpeq", "≐": "doteq", "≑": "doteqdot", "≒": "fallingdotseq", "≓": "risingdotseq",
        "≔": "coloneqq", "≖": "eqcirc", "≗": "circeq", "≜": "triangleq", "≠": "neq", "≡": "equiv",
        "≢": "nequiv", "≤": "le", "≥": "ge", "≦": "leqq", "≧": "geqq", "≨": "lneqq", "≩": "gneqq",
        "≪": "ll", "≫": "gg", "≬": "between", "≮": "nless", "≯": "ngtr", "≰": "nleq", "≱": "ngeq",
        "≲": "lesssim", "≳": "gtrsim", "≶": "lessgtr", "≷": "gtrless", "≺": "prec", "≻": "succ",
        "≼": "preccurlyeq", "≽": "succcurlyeq", "≾": "precsim", "≿": "succsim", "⊀": "nprec",
        "⊁": "nsucc", "⊂": "subset", "⊃": "supset", "⊄": "nsubset", "⊅": "nsupset", "⊆": "subseteq",
        "⊇": "supseteq", "⊈": "nsubseteq", "⊉": "nsupseteq", "⊊": "subsetneq", "⊋": "supsetneq",
        "⊎": "uplus", "⊏": "sqsubset", "⊐": "sqsupset", "⊑": "sqsubseteq", "⊒": "sqsupseteq",
        "⊓": "sqcap", "⊔": "sqcup", "⊕": "oplus", "⊖": "ominus", "⊗": "otimes", "⊘": "oslash",
        "⊙": "odot", "⊚": "circledcirc", "⊛": "circledast", "⊝": "circleddash", "⊞": "boxplus",
        "⊟": "boxminus", "⊠": "boxtimes", "⊡": "boxdot", "⊢": "vdash", "⊣": "dashv", "⊤": "top",
        "⊥": "perp", "⊨": "models", "⊩": "Vdash", "⊪": "Vvdash", "⊬": "nvdash", "⊭": "nvDash",
        "⊮": "nVdash", "⊯": "nVDash", "⊲": "vartriangleleft", "⊳": "vartriangleright", "⊴": "unlhd",
        "⊵": "unrhd", "⊶": "origof", "⊷": "imageof", "⊸": "multimap", "⊺": "intercal",
        "⊻": "veebar", "⊼": "barwedge", "⋀": "bigwedge", "⋁": "bigvee", "⋂": "bigcap",
        "⋃": "bigcup", "⋄": "diamond", "⋅": "cdotp", "⋆": "star", "⋇": "divideontimes",
        "⋈": "bowtie", "⋉": "ltimes", "⋊": "rtimes", "⋋": "leftthreetimes", "⋌": "rightthreetimes",
        "⋍": "backsimeq", "⋎": "curlyvee", "⋏": "curlywedge", "⋐": "Subset", "⋑": "Supset",
        "⋒": "Cap", "⋓": "Cup", "⋖": "lessdot", "⋗": "gtrdot", "⋘": "lll", "⋙": "ggg",
        "⋚": "lesseqgtr", "⋛": "gtreqless", "⋞": "curlyeqprec", "⋟": "curlyeqsucc", "⋠": "npreceq",
        "⋡": "nsucceq", "⋦": "lnsim", "⋧": "gnsim", "⋨": "precnsim", "⋩": "succnsim",
        "⋪": "ntriangleleft", "⋫": "ntriangleright", "⋬": "ntrianglelefteq",
        "⋭": "ntrianglerighteq", "⋮": "varvdots", "⋱": "ddots", "⌈": "lceil", "⌉": "rceil",
        "⌊": "lfloor", "⌋": "rfloor", "⌢": "frown", "⌣": "smile", "■": "blacksquare", "□": "square",
        "▲": "blacktriangle", "△": "triangle", "▶": "blacktriangleright", "▼": "blacktriangledown",
        "▽": "triangledown", "◀": "blacktriangleleft", "◊": "lozenge", "◯": "bigcirc",
        "♠": "spadesuit", "♡": "heartsuit", "♢": "diamondsuit", "♣": "clubsuit", "♭": "flat",
        "♮": "natural", "♯": "sharp", "✓": "checkmark", "✠": "maltese", "⟦": "llbracket",
        "⟧": "rrbracket", "⟨": "langle", "⟩": "rangle", "⟮": "lgroup", "⟯": "rgroup",
        "⟵": "longleftarrow", "⟶": "longrightarrow", "⟷": "longleftrightarrow",
        "⟸": "Longleftarrow", "⟹": "Longrightarrow", "⟺": "Longleftrightarrow", "⟼": "longmapsto",
        "⨀": "bigodot", "⨁": "bigoplus", "⨂": "bigotimes", "⨄": "biguplus", "⨆": "bigsqcup",
        "⨿": "amalg", "⩽": "leqslant", "⩾": "geqslant", "⪅": "lessapprox", "⪆": "gtrapprox",
        "⪇": "lneq", "⪈": "gneq", "⪉": "lnapprox", "⪊": "gnapprox", "⪋": "lesseqqgtr",
        "⪌": "gtreqqless", "⪕": "eqslantless", "⪖": "eqslantgtr", "⪯": "preceq", "⪰": "succeq",
    ]
    /// Double-struck capitals that have their own Unicode character (KaTeX
    /// reads them as `\mathbb`).
    static let unicodeLetters: [Character: String] = [
        "ℂ": #"\mathbb{C}"#, "ℍ": #"\mathbb{H}"#, "ℕ": #"\mathbb{N}"#, "ℙ": #"\mathbb{P}"#,
        "ℚ": #"\mathbb{Q}"#, "ℝ": #"\mathbb{R}"#, "ℤ": #"\mathbb{Z}"#,
    ]
}
