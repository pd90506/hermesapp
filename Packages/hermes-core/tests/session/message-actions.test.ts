import { describe, expect, test } from 'vitest'
import {
  ConversationMarkdown, PromptMarks, PromptPicks, makeItem, messageTimeText, queuedStatus, transcriptBlocks,
  type TranscriptItem,
} from '../../src/index.ts'

const user = (id: string, text: string): TranscriptItem => makeItem(id, 'user', text)
const reply = (id: string, text: string): TranscriptItem => makeItem(id, 'assistant', text)

describe('Copy Message and Copy Conversation', () => {
  test('a message copies its Markdown; a tool row without text its name and detail', () => {
    expect(ConversationMarkdown.messageSource(reply('a', '**bold**'))).toBe('**bold**')
    const tool = { ...makeItem('t', 'tool', ''), toolName: 'terminal', detail: 'ls -la' }
    expect(ConversationMarkdown.messageSource(tool)).toBe('terminal\nls -la')
  })

  test('the conversation is a section per row, queued prompts left out', () => {
    const items = [user('u', 'Hi'), reply('a', 'Hello'), { ...user('q', 'later'), outgoingStatus: queuedStatus }]
    expect(ConversationMarkdown.export(items)).toBe('## User\n\nHi\n\n## Assistant\n\nHello')
  })

  test('the newest bar is the last prompt or reply with text', () => {
    expect(ConversationMarkdown.newestMessageID([user('u', 'Hi'), reply('a', 'Hello')])).toBe('a')
    // A reply with no text yet: the bar stays on the prompt; a tool after a reply leaves it there.
    expect(ConversationMarkdown.newestMessageID([user('u', 'Hi'), reply('a', ' ')])).toBe('u')
    expect(ConversationMarkdown.newestMessageID([user('u', 'Hi'), reply('a', 'Hello'), makeItem('t', 'tool', '')])).toBe('a')
    expect(ConversationMarkdown.newestMessageID([])).toBeUndefined()
  })
})

describe('message times', () => {
  const now = new Date(2026, 10, 19, 15, 40)
  test('today is the clock; yesterday says so; earlier days have the date', () => {
    expect(messageTimeText(new Date(2026, 10, 19, 15, 27), now, 'en-US')).toBe('3:27 PM')
    expect(messageTimeText(new Date(2026, 10, 18, 15, 27), now, 'en-US')).toBe('Yesterday, 3:27 PM')
    expect(messageTimeText(new Date(2026, 8, 28, 15, 27), now, 'en-US')).toBe('Sep 28, 3:27 PM')
  })
})

describe('prompt marks', () => {
  test('each prompt is marked, oldest first; replies and queued prompts are not', () => {
    const items = [user('u1', 'first'), reply('a1', 'one'), user('u2', 'second'), { ...user('q', 'q'), outgoingStatus: queuedStatus }]
    expect(PromptMarks.marks(items)).toEqual([{ id: 'u1', label: 'first' }, { id: 'u2', label: 'second' }])
  })

  test('the label is the first line with text, its spaces collapsed, and a long one is cut', () => {
    expect(PromptMarks.label(user('u', '\n  Fix   the build \nthen test'))).toBe('Fix the build')
    const long = PromptMarks.label(user('u', 'word '.repeat(30)))
    expect([...long].length).toBeLessThanOrEqual(PromptMarks.labelLimit)
    expect(long.endsWith('word…')).toBe(true)
    expect(PromptMarks.label(user('s', 'short'), 5)).toBe('short')
  })

  test('a prompt with only files or images is labelled with them', () => {
    expect(PromptMarks.label({ ...user('f', ''), attachments: ['notes.md', 'plan.pdf'] })).toBe('notes.md, plan.pdf')
    expect(PromptMarks.label(user('i', ''))).toBe('Image')
    expect(PromptMarks.label({ ...user('i', ''), images: [{ name: 'a', position: 0 }, { name: 'b', position: 1 }] })).toBe('2 images')
  })

  const items = [user('u1', 'one'), reply('a1', 'r1'), user('u2', 'two'), reply('a2', 'r2')]
  const blocks = transcriptBlocks(items)
  const marks = PromptMarks.marks(items)

  test('the chat is at the last prompt at or above the top block on screen', () => {
    expect(PromptMarks.current(blocks, marks, new Set(['a1', 'u2']))).toBe('u1')
    expect(PromptMarks.current(blocks, marks, new Set(['a2']))).toBe('u2')
    expect(PromptMarks.current(blocks, marks, new Set())).toBeUndefined()
    expect(PromptMarks.current(blocks, marks, new Set(['gone']))).toBeUndefined()
  })

  test('a block above every prompt is at the first', () => {
    const withNote = transcriptBlocks([makeItem('s', 'system', 'note'), ...items])
    expect(PromptMarks.current(withNote, marks, new Set(['s']))).toBe('u1')
  })

  test('a chat at its end is at its last prompt; a pick wins while it holds', () => {
    expect(PromptMarks.current(blocks, marks, new Set(['a1', 'u2', 'a2']), true)).toBe('u2')
    expect(PromptMarks.current(blocks, marks, new Set(['a1', 'u2', 'a2']), true, 'u1')).toBe('u1')
    expect(PromptMarks.current(blocks, marks, new Set(), false, 'u1')).toBe('u1')
    expect(PromptMarks.current(blocks, marks, new Set(['a2']), true, 'gone')).toBe('u2')
  })

  test('a pick holds until its block, once on screen, leaves it', () => {
    const pick = PromptPicks.pick('u1')
    const before = PromptPicks.holding(pick, new Set(['a2']), blocks)
    expect(before?.wasShown).toBe(false)
    const shown = PromptPicks.holding(before!, new Set(['u1', 'a1']), blocks)
    expect(shown?.wasShown).toBe(true)
    expect(PromptPicks.holding(shown!, new Set(['a2']), blocks)).toBeUndefined()
    expect(PromptPicks.holding(PromptPicks.pick('gone'), new Set(), blocks)).toBeUndefined()
  })
})
