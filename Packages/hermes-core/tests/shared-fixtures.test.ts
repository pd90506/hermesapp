import { describe, expect, test } from 'vitest'
import bots from '../../fixtures/bots.json' with { type: 'json' }
import endpoint from '../../fixtures/endpoint.json' with { type: 'json' }
import serverRequests from '../../fixtures/server-requests.json' with { type: 'json' }
import sessionList from '../../fixtures/session-list.json' with { type: 'json' }
import sessionProjection from '../../fixtures/session-projection.json' with { type: 'json' }
import turnWork from '../../fixtures/turn-work.json' with { type: 'json' }
import replyEmbeds from '../../fixtures/reply-embeds.json' with { type: 'json' }
import {
  Bot, EndpointError, TranscriptDirectives, previewTarget, GatewayEndpoint, ServerRequestMethod, StepGroups, WorkSteps, declineServerRequest, defaultServerName,
  historyRows, makeItem, settledTitle, storedItems, toolCallView, transcriptBlocks, workDuration,
  type JSONValue, type ProfileRow, type SessionSummary, type StoredMessage, type ToolPhase, type TranscriptItem,
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

describe('session-projection.json', () => {
  test.each(sessionProjection.cases)('$name', (item) => {
    const shown = storedItems(item.rows as StoredMessage[], new Map(), item.startsSession).map((row) => ({
      role: row.role,
      text: row.text,
      ...(row.reasoning ? { reasoning: row.reasoning } : {}),
      ...(row.toolName ? { toolName: row.toolName } : {}),
      ...(row.detail !== undefined ? { detail: row.detail } : {}),
      ...(row.attachments.length > 0 ? { attachments: row.attachments } : {}),
      ...(row.images.length > 0 ? { images: row.images.map((image) => image.path) } : {}),
      ...(row.rowID !== undefined ? { rowID: row.rowID } : {}),
    }))
    expect(shown).toEqual(item.expected)
  })
})

describe('turn-work.json', () => {
  test.each(turnWork.turns)('$name', (item) => {
    const blocks = transcriptBlocks(storedItems(item.rows as StoredMessage[], new Map(), false), false).map((block) => {
      if (block.kind === 'item') return { role: block.item.role, text: block.item.text }
      return {
        work: {
          title: settledTitle(workDuration(block.work), block.work.wasInterrupted),
          entries: block.work.entries.map((entry) => {
            if (entry.kind === 'commentary') return { commentary: entry.item.text }
            if (entry.kind === 'card') return { card: entry.item.toolName }
            return { group: StepGroups.title(entry.group), steps: entry.group.steps.map((step) => `${WorkSteps.kind(step)} · ${WorkSteps.summary(step)}`) }
          }),
        },
      }
    })
    expect(blocks).toEqual(item.expected)
  })

  test.each(turnWork.toolCalls)('$name: $expected.title', (item) => {
    const phase = item.phase as ToolPhase
    const call: TranscriptItem = {
      ...makeItem('t', 'tool', '', phase === 'running'), toolName: item.name,
      tool: {
        toolID: 't', name: item.name, phase,
        ...('args' in item ? { args: item.args as unknown as JSONValue } : {}),
        ...('result' in item ? { result: item.result as unknown as JSONValue } : {}),
      },
    }
    const view = toolCallView(call)
    expect({ title: view.title, status: view.status, countLabel: view.countLabel ?? null }).toEqual(item.expected)
  })
})

describe('reply-embeds.json', () => {
  test.each(replyEmbeds.directives)('directives in $text', (item) => {
    expect(TranscriptDirectives.segments(item.text, item.streaming)).toEqual(item.segments)
  })

  test.each(replyEmbeds.previewTargets)('preview target of $file', (item) => {
    expect(previewTarget(item.file) ?? null).toEqual(item.target)
  })
})
