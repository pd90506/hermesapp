import { describe, expect, test } from 'vitest'
import {
  DashboardConnector, DashboardRequestError, GatewayEndpoint, MediaTags, ThumbnailCache, deliveredFileName,
  downloadDeliveredFile, fileDownloadRequest, fileKind, imageDataURL, isImagePath, type HttpClient,
} from '../../src/index.ts'
import { FakeDashboardAPI } from '../support/fake-dashboard-api.ts'

// `MEDIA:` tags, as Desktop's `renderMediaTags` / `mediaTagValues` read them (HermesKit's MediaTagsTests).
const paths = (text: string) => MediaTags.extract(text).files.map((file) => file.path)
const file = (path: string) => ({ path })

describe('MEDIA: tags', () => {
  test('a tag on its own line becomes a card and leaves the text', () => {
    const { text, files } = MediaTags.extract('Here is the report.\n\nMEDIA:/tmp/out/report.pdf\n\nAnything else?')
    expect(files).toEqual([file('/tmp/out/report.pdf')])
    expect(text).toBe('Here is the report.\n\nAnything else?')
    expect(deliveredFileName(files[0]!)).toBe('report.pdf')
    expect(fileKind('report.pdf')).toBe('pdf')
    expect(isImagePath('/tmp/out/report.pdf')).toBe(false)
  })

  test('an inline tag becomes the file name', () => {
    const { text, files } = MediaTags.extract('I saved MEDIA:/tmp/chart.png for you.')
    expect(text).toBe('I saved chart.png for you.')
    expect(files.map((each) => each.path)).toEqual(['/tmp/chart.png'])
    expect(isImagePath('/tmp/chart.png')).toBe(true)
  })

  test('sentence punctuation is not part of the path', () => {
    expect(paths('Open MEDIA:/tmp/a.pdf.')).toEqual(['/tmp/a.pdf'])
    expect(MediaTags.extract('Open MEDIA:/tmp/a.pdf.').text).toBe('Open a.pdf.')
    expect(paths('See MEDIA:relative/notes.txt, then reply')).toEqual(['relative/notes.txt'])
  })

  test('spaces inside a path with a known extension', () => {
    expect(paths('MEDIA:/Users/u/My Files/Q3 report.xlsx')).toEqual(['/Users/u/My Files/Q3 report.xlsx'])
    expect(paths('MEDIA:C:\\Users\\u\\My Files\\plan.docx')).toEqual(['C:\\Users\\u\\My Files\\plan.docx'])
  })

  test('quoted paths', () => {
    expect(paths('MEDIA:`/tmp/odd name!.log`')).toEqual(['/tmp/odd name!.log'])
    expect(paths('MEDIA:"/tmp/a b.weird"')).toEqual(['/tmp/a b.weird'])
    expect(paths("MEDIA:'/tmp/stop!.md'")).toEqual(['/tmp/stop!.md'])
  })

  test('several tags in order, each once', () => {
    expect(paths('MEDIA:/a/one.png\nMEDIA:/a/two.csv\nAgain: MEDIA:/a/one.png')).toEqual(['/a/one.png', '/a/two.csv'])
  })

  test('not a path stays text', () => {
    expect(MediaTags.extract('MEDIA: ... is how files are sent').files).toEqual([])
    expect(MediaTags.extract('plain text').text).toBe('plain text')
  })

  test('tags in code blocks are examples', () => {
    const { text, files } = MediaTags.extract('Write it like this:\n```\nMEDIA:/path/to/file.pdf\n```\nMEDIA:/real/file.pdf')
    expect(files.map((each) => each.path)).toEqual(['/real/file.pdf'])
    expect(text).toBe('Write it like this:\n```\nMEDIA:/path/to/file.pdf\n```')
  })

  test('while streaming, an unfinished last line waits', () => {
    const partial = MediaTags.extract('Done.\nMEDIA:/tmp/rep', true)
    expect(partial).toEqual({ text: 'Done.', files: [] })
    expect(MediaTags.extract('Done.\nMEDIA:/tmp/report.pdf\n', true).files.map((each) => each.path)).toEqual(['/tmp/report.pdf'])
  })

  test('files show where their tags were', () => {
    const text = [
      'Done: a black icon.', '', 'MEDIA:/s/icon/preview.png', '', 'Downloads:', '- **iOS**: 1024×1024.',
      'MEDIA:/s/icon/ios-1024.png', '- **macOS**: rounded corners.', 'MEDIA:/s/icon/macos-1024.png',
      '- **SVG master**', 'MEDIA:/s/icon/master.svg', '', 'Does this direction work?',
    ].join('\n')
    expect(MediaTags.segments(text)).toEqual([
      { kind: 'markdown', text: 'Done: a black icon.' },
      { kind: 'files', files: [file('/s/icon/preview.png')] },
      { kind: 'markdown', text: 'Downloads:\n- **iOS**: 1024×1024.' },
      { kind: 'files', files: [file('/s/icon/ios-1024.png')] },
      { kind: 'markdown', text: '- **macOS**: rounded corners.' },
      { kind: 'files', files: [file('/s/icon/macos-1024.png')] },
      { kind: 'markdown', text: '- **SVG master**' },
      { kind: 'files', files: [file('/s/icon/master.svg')] },
      { kind: 'markdown', text: 'Does this direction work?' },
    ])
    expect(isImagePath('/s/icon/master.svg')).toBe(true)
  })

  test('adjacent tags share one row, and an inline tag follows its line', () => {
    expect(MediaTags.segments('Here:\nMEDIA:/a/1.png\nMEDIA:/a/2.png')).toEqual([
      { kind: 'markdown', text: 'Here:' }, { kind: 'files', files: [file('/a/1.png'), file('/a/2.png')] },
    ])
    expect(MediaTags.segments('See MEDIA:/a/r.pdf now.\nBye')).toEqual([
      { kind: 'markdown', text: 'See r.pdf now.' }, { kind: 'files', files: [file('/a/r.pdf')] }, { kind: 'markdown', text: 'Bye' },
    ])
  })

  test('file kinds', () => {
    expect(fileKind('a.PDF')).toBe('pdf')
    expect(fileKind('data.csv')).toBe('spreadsheet')
    expect(fileKind('song.mp3')).toBe('audio')
    expect(fileKind('Makefile')).toBe('other')
  })
})

describe('stored images', () => {
  test('read from /api/media first', async () => {
    const api = new FakeDashboardAPI({ 'GET /api/media': { data_url: 'data:image/png;base64,AA==' } })
    expect(await imageDataURL(api, '/h/.hermes/images/a.png', 'coder')).toBe('data:image/png;base64,AA==')
    expect(api.calls[0]?.query).toEqual({ path: '/h/.hermes/images/a.png' })
  })

  test("another profile's upload is read with read-data-url", async () => {
    const api = new FakeDashboardAPI({ 'GET /api/fs/read-data-url': { dataUrl: 'data:image/jpeg;base64,BB==' } })
    api.on('GET /api/media', new DashboardRequestError(403, 'outside HERMES_HOME'))
    expect(await imageDataURL(api, '/h/profiles/coder/images/b.jpg', 'coder')).toBe('data:image/jpeg;base64,BB==')
    expect(api.calls[1]).toMatchObject({ path: '/api/fs/read-data-url', query: { path: '/h/profiles/coder/images/b.jpg', profile: 'coder' } })
  })

  test('a non-image path is not downloaded just for a placeholder', async () => {
    const api = new FakeDashboardAPI()
    api.on('GET /api/media', new DashboardRequestError(403, 'no'))
    await expect(imageDataURL(api, '/var/big.log', undefined)).rejects.toThrow()
    expect(api.calls).toHaveLength(1)
  })

  test('the cache reads each image once, three at a time, and retries failures after a minute', async () => {
    let now = 0
    const cache = new ThumbnailCache(async (url) => url, () => now)
    let running = 0
    let most = 0
    const reads: string[] = []
    const read = (path: string) => async () => {
      reads.push(path)
      running += 1
      most = Math.max(most, running)
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 5))
      running -= 1
      if (path === 'gone') throw new Error('404')
      return `data:${path}`
    }
    await Promise.all(['a', 'b', 'c', 'd', 'a'].map((path) => cache.load(path, read(path))))
    expect(most).toBe(3)
    expect(reads.filter((path) => path === 'a')).toHaveLength(1)
    expect(cache.state('a')).toEqual({ phase: 'loaded', url: 'data:a' })
    expect((await cache.load('gone', read('gone'))).phase).toBe('failed')
    await cache.load('gone', read('gone'))
    expect(reads.filter((path) => path === 'gone')).toHaveLength(1)
    now = 61_000
    await cache.load('gone', read('gone'))
    expect(reads.filter((path) => path === 'gone')).toHaveLength(2)
  })
})

describe('delivered files', () => {
  const connector = (credential: ConstructorParameters<typeof DashboardConnector>[1], http: HttpClient = { send: async () => ({ status: 200, body: '{}' }) }) =>
    new DashboardConnector(new GatewayEndpoint('https://hermes.example.ts.net'), credential, http, () => { throw new Error('no sockets') })

  test('a relative path names its stored session; a token goes as Bearer', async () => {
    const request = await fileDownloadRequest(connector({ kind: 'bearer', accessToken: 'tok' }), 'notes/a.pdf', 'coder', 'stored-1')
    expect(request.url).toBe('https://hermes.example.ts.net/api/fs/download?path=notes%2Fa.pdf&profile=coder&session_id=stored-1')
    expect(request.headers).toEqual({ Authorization: 'Bearer tok' })
    const absolute = await fileDownloadRequest(connector({ kind: 'bearer', accessToken: 'tok' }), '/tmp/a.pdf', undefined, 'stored-1')
    expect(absolute.url).toBe('https://hermes.example.ts.net/api/fs/download?path=%2Ftmp%2Fa.pdf')
  })

  test('a password sign-in signs in again once after a 401', async () => {
    const sent: string[] = []
    const http: HttpClient = { send: async (request) => { sent.push(request.url); return { status: 200, body: '{}' } } }
    const answers = [{ ok: false as const, status: 401, body: '' }, { ok: true as const, path: '/cache/a.pdf' }]
    const path = await downloadDeliveredFile(connector({ kind: 'password', provider: 'basic', username: 'u', password: 'p' }, http),
      '/tmp/a.pdf', undefined, undefined, async () => answers.shift()!)
    expect(path).toBe('/cache/a.pdf')
    expect(sent.some((url) => url.endsWith('/auth/password-login'))).toBe(true)
  })

  test('a refusal says why', async () => {
    await expect(downloadDeliveredFile(connector({ kind: 'bearer', accessToken: 't' }), '/gone.pdf', undefined, undefined,
      async () => ({ ok: false, status: 404, body: '{"detail":"File not found"}' }))).rejects.toThrow('File not found')
  })
})
