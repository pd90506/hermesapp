import Foundation
import Testing

@testable import HermesKit

/// Expected outputs use only constructs that SwiftMath 1.7.3's parser accepted
/// when probed on the Mac (see `LaTeXNormalizer`).
@Suite struct LaTeXNormalizerTests {
    private func normalize(_ latex: String) -> String { LaTeXNormalizer.normalize(latex) }

    @Test func supportedInputIsUnchanged() {
        for latex in [
            #"\frac{a}{b} + \sqrt[3]{x}"#,
            #"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#,
            #"\begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}"#,
            #"\left( \frac{a}{b} \right)^2"#,
            #"\text{若 } x > 0"#,
            #"\begin{aligned} a &= b \\ &= c \end{aligned}"#,
        ] {
            #expect(normalize(latex) == latex)
        }
    }

    @Test func fractionStyleCommands() {
        #expect(normalize(#"\dfrac{1}{2} + \tfrac12"#) == #"{\displaystyle\frac{1}{2}} + {\textstyle\frac{1}{2}}"#)
        #expect(normalize(#"\cfrac[l]{a}{b+\dfrac{c}{d}}"#) == #"{\displaystyle\frac{a}{b+{\displaystyle\frac{c}{d}}}}"#)
        #expect(normalize(#"\dbinom{n}{k}"#) == #"{\displaystyle\binom{n}{k}}"#)
    }

    @Test func operatorsAndFonts() {
        #expect(normalize(#"\operatorname*{arg\,max}_x \operatorname{Var}(X)"#) == #"\mathrm{arg\,max}_x \mathrm{Var}(X)"#)
        #expect(normalize(#"\boldsymbol{\mu} \mathscr{L}"#) == #"\mathbf{\mu} \mathcal{L}"#)
        #expect(normalize(#"a \equiv b \pmod{n}"#) == #"a \equiv b \quad(\mathrm{mod}\ n)"#)
        #expect(normalize(#"a \bmod b"#) == #"a \;\mathrm{mod}\; b"#)
    }

    @Test func symbols() {
        #expect(normalize(#"A \implies B \iff C"#) == #"A \Longrightarrow B \iff C"#)
        #expect(normalize(#"\lvert x \rvert + \lVert v \rVert"#) == #"| x | + \| v \|"#)
        #expect(normalize(#"\left\lvert x \right\rvert"#) == #"\left| x \right|"#)
        #expect(normalize(#"\iint f \, dA"#) == #"\int\!\!\int f \, dA"#)
        #expect(normalize(#"1, 2, \dots, n \leqslant \varnothing"#) == #"1, 2, \ldots, n \leq \emptyset"#)
        #expect(normalize(#"\nexists x \hookrightarrow \rightleftharpoons \blacksquare"#) == "∄ x ↪ ⇌ ■")
        #expect(normalize(#"a \not= b, x \not\in A, \not\subset"#) == #"a ≠ b, x \notin A, ⊄"#)
    }

    @Test func droppedSizingAndNumbering() {
        #expect(normalize(#"\big( x \Bigr] \label{eq:1} \tag*{1} \nonumber"#) == "( x ]   ")
        #expect(normalize(#"\left\{ x \middle| y \right\}"#) == #"\left\{ x | y \right\}"#)
    }

    @Test func approximations() {
        #expect(normalize(#"\boxed{x = 2}"#) == "{x = 2}")
        #expect(normalize(#"\underbrace{a+b}_{n}"#) == #"\underline{a+b}_{n}"#)
        #expect(normalize(#"\overset{def}{=}"#) == "{=}^{def}")
        #expect(normalize(#"\xrightarrow[k]{f}"#) == #"\longrightarrow^{f}_{k}"#)
        #expect(normalize(#"\overrightarrow{AB}"#) == #"\vec{AB}"#)
    }

    @Test func environments() {
        #expect(normalize(#"\begin{equation} E = mc^2 \label{e} \end{equation}"#) == " E = mc^2  ")
        #expect(normalize(#"\begin{align*} a &= b \\[4pt] c &= d \end{align*}"#)
            == #"\begin{aligned} a &= b \\ c &= d \end{aligned}"#)
        #expect(normalize(#"\begin{align} a &= b & c &= d \end{align}"#)
            == #"\begin{aligned} a &= b \quad  c \quad = d \end{aligned}"#)
        #expect(normalize(#"\begin{align} a \\ b \end{align}"#) == #"\begin{gather} a \\ b \end{gather}"#)
        #expect(normalize(#"\begin{array}{c|c} a & b \\ \hline c & d \end{array}"#)
            == #"\begin{matrix} a & b \\  c & d \end{matrix}"#)
        #expect(normalize(#"\begin{smallmatrix} a \end{smallmatrix}"#) == #"\begin{matrix} a \end{matrix}"#)
        #expect(normalize(#"\begin{bmatrix*}[r] 1 \end{bmatrix*}"#) == #"\begin{bmatrix} 1 \end{bmatrix}"#)
        #expect(normalize(#"\begin{cases} a \\ b \end{cases}"#) == #"\begin{cases} a &\\ b &\end{cases}"#)
        #expect(normalize(#"\begin{multline} a \\ b \end{multline}"#) == #"\begin{gather} a \\ b \end{gather}"#)
    }

    @Test func nestedEnvironmentsKeepTheirColumns() {
        let latex = #"\begin{align} f &= \begin{pmatrix} 1 & 2 & 3 \end{pmatrix} \end{align}"#
        #expect(normalize(latex) == #"\begin{aligned} f &= \begin{pmatrix} 1 & 2 & 3 \end{pmatrix} \end{aligned}"#)
    }

    @Test func malformedInputDoesNotCrash() {
        for latex in [#"\"#, #"\frac{1"#, #"\dfrac{a"#, #"\begin{align"#, #"\begin{align} a &= b"#, "{{}", #"\not"#, #"\\["#] {
            _ = normalize(latex)
        }
        #expect(normalize(#"\begin{align} a &= b"#) == #"\begin{aligned} a &= b\end{aligned}"#)
    }
}
