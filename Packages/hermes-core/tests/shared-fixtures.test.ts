import { describe, expect, test } from 'vitest'
import bots from '../../fixtures/bots.json' with { type: 'json' }
import endpoint from '../../fixtures/endpoint.json' with { type: 'json' }
import serverRequests from '../../fixtures/server-requests.json' with { type: 'json' }
import sessionList from '../../fixtures/session-list.json' with { type: 'json' }
import {
  Bot, EndpointError, GatewayEndpoint, ServerRequestMethod, declineServerRequest, defaultServerName, historyRows,
  type ProfileRow, type SessionSummary,
} from '../src/index.ts'

// The same cases as HermesKit's SharedFixtureTests.swift (Packages/fixtures/README.md).

describe('endpoint.json', () => {
  test.each(endpoint.normalize)('normalises $input', (item) => {
    if ('error' in item && item.error) {
      let thrown: unknown
      try { new GatewayEndpoint(item.input) } catch (error) { thrown = error }
      expect(thrown).toBeInstanceOf(EndpointError)
      expect((thrown as EndpointError).kind).toBe(item.error)
    } else {
      expect(new GatewayEndpoint(item.input).baseURL).toBe(item.base)
    }
  })

  test.each(endpoint.webSocket)('WebSocket URL of $input', (item) => {
    expect(new GatewayEndpoint(item.input).webSocketURL([['ticket', item.ticket]])).toBe(item.url)
  })

  test.each(endpoint.serverName)('server name of $url', (item) => {
    expect(defaultServerName(item.url) ?? null).toBe(item.name)
  })
})

describe('bots.json', () => {
  const roster = Bot.roster(bots.profiles as ProfileRow[])

  test('roster order: default first, then the server order', () => {
    expect(roster.map((bot) => bot.name)).toEqual(bots.expected.map((item) => item.name))
  })

  test.each(bots.expected)('$name', (item) => {
    const bot = roster.find((candidate) => candidate.name === item.name)!
    expect(bot.displayName).toBe(item.displayName)
    expect(bot.preview ?? null).toBe(item.preview)
    expect([...bot.chatStoredIDs].sort()).toEqual([...item.chatStoredIDs].sort())
    expect(bot.activity(bots.now)).toBe(item.activity)
  })
})

test('session-list.json: listed rows', () => {
  const bot = new Bot({ name: 'default', canonical_session: sessionList.canonical_session })
  const listed = historyRows(sessionList.rows as SessionSummary[], bot)
  expect(listed.map((row) => row.id)).toEqual(sessionList.listed)
})

describe('server-requests.json', () => {
  test.each(serverRequests.declined)('declines $method with $code', (item) => {
    expect(declineServerRequest(item.method).code).toBe(item.code)
  })

  test('supported requests', () => {
    expect([...ServerRequestMethod.mvpSupported].sort()).toEqual([...serverRequests.supported].sort())
  })
})
