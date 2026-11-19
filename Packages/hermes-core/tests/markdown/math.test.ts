import { describe, expect, it } from 'vitest'
import { inlineMath, normalizeMath } from '../../src/markdown/math.ts'

// Cases from HermesKit's InlineParserTests and MarkdownParserTests, so both apps read
// the same text as maths.
describe('inline maths', () => {
  it('leaves prices as text', () => {
    expect(inlineMath('costs $5 and $10')).toBe('costs \\$5 and \\$10')
    expect(inlineMath('between $5-$10, or $1,000/$2,000')).toBe('between \\$5-\\$10, or \\$1,000/\\$2,000')
    expect(inlineMath('price: $ 5 $')).toBe('price: \\$ 5 \\$')
    expect(inlineMath('成本是$5，而$x$')).toBe('成本是\\$5，而$x$')
  })

  it('keeps escaped dollars escaped', () => {
    expect(inlineMath('escaped \\$x\\$')).toBe('escaped \\$x\\$')
  })

  it('reads dollar maths', () => {
    expect(inlineMath('so $x^2 + y$ holds')).toBe('so $x^2 + y$ holds')
    expect(inlineMath('costs $5 or $x$')).toBe('costs \\$5 or $x$')
    expect(inlineMath('$\\text{\\$}5$')).toBe('$\\text{\\$}5$')
  })

  it('reads double dollars on a line with text as inline display maths', () => {
    expect(inlineMath('$$E=mc^2$$ inline')).toBe('$\\displaystyle E=mc^2$ inline')
  })

  it('reads backslash delimiters', () => {
    expect(inlineMath('then \\(a_i\\) and \\[b\\]')).toBe('then $a_i$ and $\\displaystyle b$')
    expect(inlineMath('just \\( a paren')).toBe('just \\( a paren')
  })

  it('treats shell variables as text', () => {
    expect(inlineMath('cd $HOME/$USER')).toBe('cd \\$HOME/\\$USER')
  })

  it('never spans or enters code spans', () => {
    expect(inlineMath('a $b `c$` d')).toBe('a \\$b `c$` d')
    expect(inlineMath('run `echo $PATH` now')).toBe('run `echo $PATH` now')
  })

  it('stays linear on many openers without closers', () => {
    const line = '\\( '.repeat(20_000)
    const started = Date.now()
    inlineMath(line)
    expect(Date.now() - started).toBeLessThan(1000)
  })
})

describe('display maths', () => {
  it('turns each delimiter into a display block', () => {
    const text = 'Before\n$$\n\\frac{a}{b}\n$$\n\\[ x^2 \\]\n$$ y $$\n\\begin{align}\na &= b\n\\end{align}\nafter'
    expect(normalizeMath(text)).toBe([
      'Before',
      '$$', '\\frac{a}{b}', '$$',
      '$$', 'x^2', '$$',
      '$$', 'y', '$$',
      '$$', '\\begin{align}\na &= b\n\\end{align}', '$$',
      'after',
    ].join('\n'))
  })

  it('continues the text after a closer', () => {
    expect(normalizeMath('$$\nx\n$$ where x is real')).toBe('$$\nx\n$$\nwhere x is real')
  })

  it('keeps double dollars with text around them inline', () => {
    expect(normalizeMath('$$a$$ and $$b$$')).toBe('$\\displaystyle a$ and $\\displaystyle b$')
  })

  it('opens an unclosed block only while streaming', () => {
    expect(normalizeMath('$$\n\\sum_i x_i\n$', { streaming: true })).toBe('$$\n\\sum_i x_i\n$$')
    expect(normalizeMath('\\[\nx')).toBe('\\[\nx')
  })

  it('leaves fenced code alone', () => {
    const text = '```swift\nlet s = "$$"\nlet t = "$5 and $6"\n```\ncosts $5'
    expect(normalizeMath(text)).toBe('```swift\nlet s = "$$"\nlet t = "$5 and $6"\n```\ncosts \\$5')
    expect(normalizeMath('~~~~\n$x$\n~~~\n$y$')).toBe('~~~~\n$x$\n~~~\n$y$')
  })

  it('returns text without maths unchanged', () => {
    const text = '# Title\n\nPlain text.'
    expect(normalizeMath(text)).toBe(text)
  })
})
