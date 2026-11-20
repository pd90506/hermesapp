import { describe, expect, it } from 'vitest'
import { chatTitle } from '../../src/session/chat-title.ts'

const bots = [{ name: 'ratio', displayName: 'Ratio' }]

describe('chatTitle', () => {
  it('names a session by its title, or New Chat before it has one', () => {
    expect(chatTitle({ kind: 'session', title: ' Fix the build ', profile: 'ratio' }, bots)).toBe('Fix the build')
    expect(chatTitle({ kind: 'session', profile: 'ratio' }, bots)).toBe('New Chat')
    expect(chatTitle({ kind: 'session', title: '' }, bots, true)).toBe('Chat')
  })

  it('names a Bot Chat by its bot', () => {
    expect(chatTitle({ kind: 'botChat', title: 'ignored', profile: 'ratio' }, bots)).toBe('Ratio')
    expect(chatTitle({ kind: 'botChat', profile: 'other' }, bots)).toBe('other')
    expect(chatTitle({ kind: 'botChat' }, bots)).toBe('Hermes')
  })

  it('names a side chat with its bot', () => {
    expect(chatTitle({ kind: 'sideChat', title: 'Plan', profile: 'ratio' }, bots)).toBe('Plan · Ratio')
    expect(chatTitle({ kind: 'sideChat', profile: 'ratio' }, bots)).toBe('Side chat · Ratio')
    expect(chatTitle({ kind: 'sideChat' }, bots)).toBe('Side chat')
  })
})
