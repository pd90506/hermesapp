import { describe, expect, it } from 'vitest'
import {
  cjkLanguageOf, externalLinkTarget, fenceLanguage, remarkKeepLineBreaks, type MarkdownNode,
} from '../../src/index.ts'

describe('externalLinkTarget', () => {
  it('opens web and mail addresses', () => {
    expect(externalLinkTarget('https://example.com/a?b=1')).toBe('https://example.com/a?b=1')
    expect(externalLinkTarget(' http://example.com ')).toBe('http://example.com/')
    expect(externalLinkTarget('mailto:someone@example.com')).toBe('mailto:someone@example.com')
    expect(externalLinkTarget('www.example.com')).toBe('https://www.example.com/')
  })

  it('follows nothing else', () => {
    for (const href of [undefined, '', '#top', 'notes.md', '/etc/passwd', 'file:///etc/passwd',
      'javascript:alert(1)', 'https://user:pass@example.com', 'C:\\Users\\a.txt']) {
      expect(externalLinkTarget(href)).toBeUndefined()
    }
  })
})

describe('cjkLanguageOf', () => {
  it('marks Han text with the preferred language', () => {
    expect(cjkLanguageOf('这是中文')).toBe('zh-Hans')
    expect(cjkLanguageOf('這是中文', 'zh-Hant')).toBe('zh-Hant')
  })

  it('recognises Japanese and Korean by their scripts', () => {
    expect(cjkLanguageOf('日本語のテキスト')).toBe('ja')
    expect(cjkLanguageOf('한국어')).toBe('ko')
  })

  it('leaves other text alone', () => {
    expect(cjkLanguageOf('Hello, world')).toBeUndefined()
  })
})

describe('fenceLanguage', () => {
  it('reads the language class', () => {
    expect(fenceLanguage('language-TypeScript')).toBe('typescript')
    expect(fenceLanguage('foo language-py')).toBe('py')
    expect(fenceLanguage(undefined)).toBeUndefined()
  })
})

describe('remarkKeepLineBreaks', () => {
  it('turns soft breaks into line breaks', () => {
    const tree: MarkdownNode = { type: 'root', children: [
      { type: 'paragraph', children: [
        { type: 'text', value: 'one\ntwo  \n three' },
        { type: 'strong', children: [{ type: 'text', value: 'a\nb' }] },
      ] },
      { type: 'code', value: 'x\ny' },
    ] }
    remarkKeepLineBreaks()(tree)
    expect(tree.children?.[0]?.children).toEqual([
      { type: 'text', value: 'one' }, { type: 'break' }, { type: 'text', value: 'two' }, { type: 'break' },
      { type: 'text', value: 'three' },
      { type: 'strong', children: [{ type: 'text', value: 'a' }, { type: 'break' }, { type: 'text', value: 'b' }] },
    ])
    expect(tree.children?.[1]).toEqual({ type: 'code', value: 'x\ny' })
  })
})
