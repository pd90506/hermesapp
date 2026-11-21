import { describe, expect, test } from 'vitest'
import { TranscriptDirectives, previewTarget, proxiedImageDataURL, readGatewayText } from '../../src/index.ts'
import { FakeDashboardAPI } from '../support/fake-dashboard-api.ts'

// `::name{…}` directives, as Desktop's `transcript-directives.ts` reads them.
const split = (text: string, streaming = false) => TranscriptDirectives.segments(text, streaming)

describe('transcript directives', () => {
  test('a directive on its own line splits the reply around it', () => {
    expect(split('Here is the chart.\n\n::preview{file="chart.html"}\n\nAnything else?')).toEqual([
      { kind: 'markdown', text: 'Here is the chart.' },
      { kind: 'directive', name: 'preview', attrs: { file: 'chart.html' }, source: '::preview{file="chart.html"}' },
      { kind: 'markdown', text: 'Anything else?' },
    ])
  })

  test('one at the end of a sentence still draws, after the sentence', () => {
    expect(split('Open it: ::preview{file=\'/tmp/a.html\' height="480"} now')).toEqual([
      { kind: 'markdown', text: 'Open it:' },
      { kind: 'directive', name: 'preview', attrs: { file: '/tmp/a.html', height: '480' }, source: '::preview{file=\'/tmp/a.html\' height="480"}' },
      { kind: 'markdown', text: 'now' },
    ])
  })

  test('only a name the app claims is a directive', () => {
    expect(split('::chart{file="a.html"}')).toEqual([{ kind: 'markdown', text: '::chart{file="a.html"}' }])
  })

  test('C++ scopes, code fences and an unclosed brace stay text', () => {
    expect(split('Use std::preview{x} here')).toEqual([{ kind: 'markdown', text: 'Use std::preview{x} here' }])
    const fenced = '```\n::preview{file="a.html"}\n```'
    expect(split(fenced)).toEqual([{ kind: 'markdown', text: fenced }])
    expect(split('::preview{file="a.html"')).toEqual([{ kind: 'markdown', text: '::preview{file="a.html"' }])
  })

  test('while streaming, a directive still being written waits', () => {
    expect(split('Done.\n::preview{file="a.ht', true)).toEqual([{ kind: 'markdown', text: 'Done.' }])
    expect(split('Done.\n::preview{file="a.html"}', true).map((segment) => segment.kind)).toEqual(['markdown', 'directive'])
  })

  test('an autolink copied into an attribute is unwrapped', () => {
    const [segment] = split('::preview{file="<https://example.com/a.html>"}')
    expect(segment).toMatchObject({ kind: 'directive', attrs: { file: 'https://example.com/a.html' } })
  })

  test('the target: a page, another file, or a web address', () => {
    expect(previewTarget('chart.html')).toEqual({ kind: 'html', path: 'chart.html' })
    expect(previewTarget('`/tmp/Report.HTM`')).toEqual({ kind: 'html', path: '/tmp/Report.HTM' })
    expect(previewTarget('file:///C:/work/a%20b.html')).toEqual({ kind: 'html', path: 'C:/work/a b.html' })
    expect(previewTarget('/tmp/data.csv')).toEqual({ kind: 'file', path: '/tmp/data.csv' })
    expect(previewTarget('https://example.com/a.html')).toEqual({ kind: 'url', url: 'https://example.com/a.html' })
    expect(previewTarget('  ')).toBeUndefined()
  })
})

describe('gateway reads for embeds', () => {
  test('a page is read as text; the chat is named only for a relative path', async () => {
    const api = new FakeDashboardAPI({ 'GET /api/fs/read-text': { text: '<p>hi</p>', binary: false, truncated: false } })
    expect(await readGatewayText(api, 'chart.html', 'coder', 'stored-1')).toEqual({ text: '<p>hi</p>', binary: false, truncated: false })
    await readGatewayText(api, '/tmp/chart.html', 'coder', 'stored-1')
    expect(api.calls.map((call) => call.query)).toEqual([
      { path: 'chart.html', profile: 'coder', session_id: 'stored-1' },
      { path: '/tmp/chart.html', profile: 'coder' },
    ])
  })

  test('a web image through the gateway proxy', async () => {
    const api = new FakeDashboardAPI({ 'GET /api/media/proxy': { data_url: 'data:image/png;base64,AA==' } })
    expect(await proxiedImageDataURL(api, 'https://cdn.example.com/x.png')).toBe('data:image/png;base64,AA==')
    expect(api.calls[0]?.query).toEqual({ url: 'https://cdn.example.com/x.png' })
    const refusing = new FakeDashboardAPI({ 'GET /api/media/proxy': { data_url: 'data:text/html;base64,AA==' } })
    await expect(proxiedImageDataURL(refusing, 'https://x/y.png')).rejects.toThrow()
  })
})
