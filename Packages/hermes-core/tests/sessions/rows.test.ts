import { describe, expect, test } from 'vitest'
import {
  Bot, SessionActionError, SessionActions, SessionPins, SessionReadMarks, isReply, searchResults, snippetSegments,
  sortByListDate, activityCacheKey, avatarColor, avatarDataURL, type Call, type JSONValue,
} from '../../src/index.ts'

describe('pins', () => {
  test('are per server and profile, and split the list keeping its order', () => {
    let pins = new SessionPins()
    pins = pins.setPinned(true, 'srv', 'default', 'b').setPinned(true, 'other', 'default', 'a')
    const rows = [{ id: 'a' }, { id: 'b' }, { id: 'c' }]
    expect(pins.split(rows, 'srv', 'default')).toEqual({ pinned: [{ id: 'b' }], others: [{ id: 'a' }, { id: 'c' }] })
    expect(pins.forgetServer('other').toJSON()).toEqual(['srv/default/b'])
    expect(new SessionPins(pins.toJSON()).isPinned('srv', 'default', 'b')).toBe(true)
  })
})

describe('row order and activity', () => {
  test('rows sort by list date; unread rows keep their place under the row above', () => {
    expect(sortByListDate(['a', 'b', 'c', 'd'], [10, undefined, 30, 5])).toEqual(['c', 'a', 'b', 'd'])
    expect(sortByListDate(['a', 'b'], [undefined, 5])).toEqual(['a', 'b'])
  })

  test('a reply is an assistant row without tool calls, not hidden', () => {
    expect(isReply({ role: 'assistant', content: 'hi' })).toBe(true)
    expect(isReply({ role: 'assistant', tool_calls: [] })).toBe(true)
    expect(isReply({ role: 'assistant', tool_calls: [{ id: 'x' }] })).toBe(false)
    expect(isReply({ role: 'assistant', display_kind: 'hidden' })).toBe(false)
    expect(isReply({ role: 'user' })).toBe(false)
  })

  test('the cache key follows the tip and its message count', () => {
    expect(activityCacheKey('p', { id: 'a', resolved_id: 'tip', message_count: 4 })).toBe('p/tip/4')
    expect(activityCacheKey('p', { id: 'a' })).toBeUndefined()
  })
})

describe('read marks', () => {
  test('replies before marks were kept count as seen; newer ones are unread until seen', () => {
    const marks = new SessionReadMarks().start(1000)
    expect(marks.isUnread('p', 'a', 900)).toBe(false)
    expect(marks.isUnread('p', 'a', 1100)).toBe(true)
    const seen = marks.markSeen('p', 'a', 1100)
    expect(seen.isUnread('p', 'a', 1100)).toBe(false)
    expect(seen.markSeen('p', 'a', 1000)).toBe(seen)
    expect(SessionReadMarks.fromJSON(JSON.parse(JSON.stringify(seen))).seenThrough('p', 'a')).toBe(1100)
  })
})

describe('search', () => {
  test('snippets split at the FTS markers, on one line', () => {
    expect(snippetSegments('a >>>b<<< c\nd >>>e')).toEqual([
      { text: 'a ', isMatch: false }, { text: 'b', isMatch: true }, { text: ' c d ', isMatch: false }, { text: 'e', isMatch: true },
    ])
  })

  test('hits become listed rows where there are some; other sources and duplicates go', () => {
    const bot = new Bot({ name: 'default', canonical_session: { id: 'bot' } })
    const results = searchResults([
      { session_id: 'tip', snippet: 'x' },
      { session_id: 'cron1', source: 'cron' },
      { session_id: 'new', title: 'Old chat', source: 'tui' },
      { session_id: 'a' },
      { session_id: 'bot' },
    ], [{ id: 'a', resolved_id: 'tip', title: 'Listed' }], bot)
    expect(results.map((result) => [result.row.id, result.row.title, result.isBotChat])).toEqual([
      ['a', 'Listed', false], ['new', 'Old chat', false], ['bot', undefined, true],
    ])
  })
})

describe('row actions', () => {
  const bot = new Bot({ name: 'default', canonical_session: { id: 'bot' } })
  const calls: Array<[string, unknown]> = []
  const call: Call = async (method: string, params: JSONValue): Promise<JSONValue> => {
    calls.push([method, params])
    if (method === 'session.branch_stored') return { stored_session_id: 'copy' }
    if (method === 'session.title') return { title: 'New' }
    return {}
  }

  test('go over JSON-RPC with the profile; fork stores the copy under desktop', async () => {
    calls.length = 0
    await SessionActions.archive(call, { id: 'a' }, 'default', bot)
    await SessionActions.delete(call, { id: 'a' }, 'default', bot)
    expect(await SessionActions.fork(call, { id: 'a' }, 'default', bot)).toBe('copy')
    expect(await SessionActions.rename(call, { id: 'a' }, bot, ' New ', 'rt1')).toBe('New')
    expect(calls).toEqual([
      ['session.archive', { session_id: 'a', archived: true, profile: 'default' }],
      ['session.delete', { session_id: 'a', profile: 'default' }],
      ['session.branch_stored', { parent_session_id: 'a', profile: 'default', source: 'desktop' }],
      ['session.title', { session_id: 'rt1', title: 'New' }],
    ])
  })

  test('the Bot Chat and its title are protected; a closed chat can\'t be renamed', async () => {
    await expect(SessionActions.delete(call, { id: 'bot' }, 'default', bot)).rejects.toThrow(SessionActionError)
    await expect(SessionActions.archive(call, { id: 'x', title: 'Bot Chat' }, 'default', bot)).rejects.toThrow(SessionActionError)
    await expect(SessionActions.rename(call, { id: 'a' }, bot, 'bot chat', 'rt')).rejects.toMatchObject({ kind: 'reservedTitle' })
    await expect(SessionActions.rename(call, { id: 'a' }, bot, 'Fine', undefined)).rejects.toMatchObject({ kind: 'notOpen' })
  })
})

describe('avatars', () => {
  test('data URLs pass, bare base64 becomes one; Desktop\'s colour is read', () => {
    expect(avatarDataURL('data:image/png;base64,AAAA')).toBe('data:image/png;base64,AAAA')
    expect(avatarDataURL('AAAA')).toBe('data:image/png;base64,AAAA')
    expect(avatarDataURL('<svg>')).toBeUndefined()
    expect(avatarColor(new Bot({ name: 'x', ui_meta: { 'hermes-bots': { color: '#AbC' } } }))).toBe('#aabbcc')
    expect(avatarColor(new Bot({ name: 'x' }))).toBeUndefined()
  })
})
