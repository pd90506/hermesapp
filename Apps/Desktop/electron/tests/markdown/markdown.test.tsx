import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Markdown } from '../../src/renderer/features/markdown/Markdown.tsx'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function show(text: string, streaming = false) {
  return render(<Markdown text={text} streaming={streaming} />).container
}

describe('Markdown', () => {
  it('draws headings, emphasis, lists, task boxes and quotes', () => {
    const view = show('# Title\n\nSome **bold** and *em* and `code`.\n\n- a\n- [x] done\n- [ ] open\n\n1. one\n2. two\n\n> quoted\n\n---')
    expect(view.querySelector('h1')?.textContent).toBe('Title')
    expect(view.querySelector('strong')?.textContent).toBe('bold')
    expect(view.querySelector('em')?.textContent).toBe('em')
    expect(view.querySelector('code')?.textContent).toBe('code')
    expect([...view.querySelectorAll('li')].map((item) => item.dataset.task ?? '')).toEqual(['', 'done', 'open', '', ''])
    // The box is drawn as the item's marker, not as a form control.
    expect(view.querySelector('input')).toBeNull()
    expect(view.querySelector('ol')?.children).toHaveLength(2)
    expect(view.querySelector('blockquote')?.textContent?.trim()).toBe('quoted')
    expect(screen.getByRole('separator')).toBeTruthy()
  })

  it('keeps line breaks inside a paragraph', () => {
    const view = show('line one\nline two')
    expect(view.querySelectorAll('p br')).toHaveLength(1)
  })

  it('typesets maths and leaves prices as text', () => {
    const view = show('Costs $5 and $10, while $x^2$ grows.\n\n\\[\n\\frac{a}{b}\n\\]')
    expect(view.querySelector('p')?.textContent).toContain('Costs $5 and $10')
    expect(view.querySelectorAll('.katex')).toHaveLength(2)
    expect(view.querySelector('.katex-display')).toBeTruthy()
  })

  it('opens web links through the main process and leaves others inert', () => {
    const open = vi.fn(async () => true)
    vi.stubGlobal('talaria', { links: { open } })
    const view = show('[site](https://example.com/a) and [notes](notes.md)')
    const link = screen.getByRole('link', { name: 'site' })
    fireEvent.click(link)
    expect(open).toHaveBeenCalledWith('https://example.com/a')
    expect(view.querySelectorAll('a')).toHaveLength(1)
    expect(view.textContent).toContain('notes')
    expect(view.textContent).not.toContain('blocked')
  })

  it('draws a fence with its language, a Copy button and colours', async () => {
    const writeText = vi.fn(async () => undefined)
    vi.stubGlobal('navigator', { ...navigator, clipboard: { writeText } })
    const view = show('```ts\nconst a = 1\n```')
    expect(screen.getByText('ts')).toBeTruthy()
    await waitFor(() => expect(view.querySelectorAll('[style*="--token-light"]').length).toBeGreaterThan(0), { timeout: 5000 })
    expect(view.querySelector('pre')?.textContent).toBe('const a = 1')
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Copy code' })) })
    expect(writeText).toHaveBeenCalledWith('const a = 1')
    expect(screen.getByRole('button', { name: 'Copy code' }).title).toBe('Copied')
  })

  it('shows an unknown language plain', async () => {
    const view = show('```nosuchlanguage\nhello\n```')
    await new Promise((resolve) => setTimeout(resolve, 200))
    expect(view.querySelector('pre')?.textContent).toBe('hello')
    expect(view.querySelectorAll('[style*="--token-light"]')).toHaveLength(0)
  })

  it('leaves a fence that is still streaming in uncoloured', async () => {
    const view = show('```ts\nconst a', true)
    await new Promise((resolve) => setTimeout(resolve, 300))
    expect(view.querySelector('pre')?.textContent).toBe('const a')
    expect(view.querySelectorAll('[style*="--token-light"]')).toHaveLength(0)
  })

  it('lays tables out with a header, alignments and wrapping cells', () => {
    const view = show('| Item | Cost |\n|:----:|-----:|\n| A | 5 |\n| B | 6 |')
    expect([...view.querySelectorAll('th')].map((cell) => cell.textContent)).toEqual(['Item', 'Cost'])
    expect([...view.querySelectorAll('th')].map((cell) => cell.dataset.align)).toEqual(['center', 'right'])
    expect(view.querySelectorAll('tbody tr')).toHaveLength(2)
    expect(view.querySelectorAll('td > div')).toHaveLength(4)
  })

  it('marks Chinese text with its language for Chinese glyphs', () => {
    expect(show('你好，世界').querySelector('[data-markdown]')?.getAttribute('lang')).toBe('zh-Hans')
    cleanup()
    expect(show('Hello').querySelector('[data-markdown]')?.hasAttribute('lang')).toBe(false)
  })

  it('re-renders only the block that grows while streaming', () => {
    const { container, rerender } = render(<Markdown text={'# Title\n\nfirst'} streaming />)
    const heading = container.querySelector('h1')
    rerender(<Markdown text={'# Title\n\nfirst words and more'} streaming />)
    expect(container.querySelector('h1')).toBe(heading)
    expect(container.querySelector('p')?.textContent).toBe('first words and more')
  })

  it('repairs half-written Markdown at a streaming message end', () => {
    const view = show('Some **bold', true)
    expect(view.querySelector('strong')?.textContent).toBe('bold')
  })

  it('shows a huge message as plain text', () => {
    const text = '# not a heading\n' + 'x'.repeat(200_001)
    const view = show(text)
    expect(view.querySelector('h1')).toBeNull()
    expect(view.textContent?.startsWith('# not a heading')).toBe(true)
  })
})
