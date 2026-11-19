import { describe, expect, it } from 'vitest'
import { cjkLanguage } from '../src/main/cjk.ts'
import { relativeTime } from '../src/renderer/app/time.ts'
import { serverCredential } from '@talaria/hermes-core'
import { avatarPalette, fallbackColor, initials } from '../src/renderer/features/sidebar/avatar.ts'
import { status } from '../src/renderer/features/sidebar/Sidebar.tsx'

describe('cjkLanguage', () => {
  it('takes the first CJK language in the list', () => {
    expect(cjkLanguage(['en-US', 'zh-Hans-CN', 'ja-JP'])).toBe('zh-Hans')
    expect(cjkLanguage(['en-US', 'ja-JP', 'zh-CN'])).toBe('ja')
    expect(cjkLanguage(['zh-TW'])).toBe('zh-Hant')
    expect(cjkLanguage(['zh-Hant-HK'])).toBe('zh-Hant')
    expect(cjkLanguage(['ko-KR'])).toBe('ko')
  })

  it('falls back to Simplified Chinese on an English system', () => {
    expect(cjkLanguage(['en-US', 'en-GB'])).toBe('zh-Hans')
    expect(cjkLanguage([])).toBe('zh-Hans')
  })
})

describe('relativeTime', () => {
  const now = new Date(2026, 10, 19, 15, 30)

  it('says Now under a minute', () => {
    expect(relativeTime(new Date(2026, 10, 19, 15, 29, 30), now)).toBe('Now')
  })

  it('counts minutes and hours today', () => {
    expect(relativeTime(new Date(2026, 10, 19, 15, 29), now)).toBe('1 minute ago')
    expect(relativeTime(new Date(2026, 10, 19, 15, 5), now)).toBe('25 minutes ago')
    expect(relativeTime(new Date(2026, 10, 19, 13, 0), now)).toBe('2 hours ago')
  })

  it('says Yesterday, then the date', () => {
    expect(relativeTime(new Date(2026, 10, 18, 23, 0), now)).toBe('Yesterday')
    expect(relativeTime(new Date(2026, 10, 2, 9, 0), now)).toBe('Nov 2')
    expect(relativeTime(new Date(2025, 0, 5, 9, 0), now)).toBe('Jan 5, 2025')
  })
})

describe('avatar', () => {
  it('takes initials as the Mac does', () => {
    expect(initials('Hermes Agent')).toBe('HA')
    expect(initials('default')).toBe('DE')
    expect(initials('小助手')).toBe('小助')
  })

  it('keeps a colour per name', () => {
    expect(fallbackColor('default')).toBe(fallbackColor('default'))
    expect(avatarPalette).toContain(fallbackColor('coder'))
  })
})

describe('status', () => {
  const url = 'https://hermes.example.com:9119/'

  it('shows the host when connected or briefly reconnecting', () => {
    expect(status({ phase: 'connected' } as never, false, url)).toBe('hermes.example.com:9119')
    expect(status({ phase: 'reconnecting' } as never, false, url)).toBe('hermes.example.com:9119')
  })

  it('says so when reconnecting takes long', () => {
    expect(status({ phase: 'reconnecting' } as never, true, url)).toBe('Reconnecting…')
    expect(status({ phase: 'connecting' } as never, true, url)).toBe('Connecting…')
    expect(status({ phase: 'failed', message: 'x' } as never, false, url)).toBe('Couldn’t connect')
  })
})

describe('serverCredential', () => {
  const server = { id: 'a', name: '', serverURL: 'https://h', authMode: 'password', provider: '', username: 'me' } as const

  it('signs in with a password through the basic provider by default', () => {
    expect(serverCredential(server, 'pw')).toEqual({ kind: 'password', provider: 'basic', username: 'me', password: 'pw' })
  })

  it('passes tokens through', () => {
    expect(serverCredential({ ...server, authMode: 'accessToken' }, 't')).toEqual({ kind: 'bearer', accessToken: 't' })
    expect(serverCredential({ ...server, authMode: 'sessionToken' }, 's')).toEqual({ kind: 'sessionToken', token: 's' })
  })
})
