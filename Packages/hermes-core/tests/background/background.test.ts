import { afterEach, describe, expect, test, vi } from 'vitest'
import {
  AlertGate, BackgroundProcessList, ConnectionAlerts, SubagentRoster, alertBody, backgroundAlertBody, currentTodoPlan,
  defaultAlertPreferences, makeItem, parseTodoPlan, setAlertOn, todoIsFinished, todoRows, todoTitle, toolText,
  type GatewayAlert, type GatewayConnection, type JSONValue, type TranscriptItem,
} from '../../src/index.ts'
import { PagedServer, eventually } from '../support/paged-server.ts'

const event = (type: string, payload: Record<string, unknown>) => ({ type, session_id: 'rt', payload: payload as JSONValue })

describe('subagents', () => {
  test('start adds a row, progress updates it, complete ends it, and a late event never revives it', () => {
    let roster = SubagentRoster.empty
    roster = roster.apply(event('subagent.progress', { subagent_id: 'a', text: 'ignored' }), 1)
    expect(roster.runs).toHaveLength(0)
    roster = roster.apply(event('subagent.start', { subagent_id: 'a', goal: 'Find the bug', task_index: 0, task_count: 2 }), 1000)
    roster = roster.apply(event('subagent.tool', { subagent_id: 'a', tool_name: 'web_search', tool_preview: 'electron notifications' }), 2000)
    roster = roster.apply(event('subagent.progress', { subagent_id: 'a', text: 'reading  the\ndocs' }), 3000)
    const live = roster.live
    expect(live).toHaveLength(1)
    expect(live[0]).toMatchObject({ goal: 'Find the bug', status: 'running', startedAt: 1000, currentTool: 'web_search' })
    expect(live[0]!.activity.map((line) => line.text)).toEqual(['Web Search("electron notifications")', 'reading the docs'])
    roster = roster.apply(event('subagent.complete', { subagent_id: 'a', status: 'timeout', duration_seconds: 30 }), 4000)
    expect(roster.runs[0]).toMatchObject({ status: 'failed', summary: 'Timed out after 30s' })
    expect(roster.live).toHaveLength(0)
    const after = roster.apply(event('subagent.progress', { subagent_id: 'a', text: 'late' }), 5000)
    expect(after).toBe(roster)
    // The next prompt drops it, and a snapshot can't bring it back.
    roster = roster.pruneFinished()
    expect(roster.runs).toHaveLength(0)
    roster = roster.reconcile([{ subagent_id: 'a', goal: 'Find the bug', status: 'running' }])
    expect(roster.runs).toHaveLength(0)
  })

  test('a snapshot drops live rows it no longer lists and adds new ones with their last tool', () => {
    let roster = SubagentRoster.empty.apply(event('subagent.start', { subagent_id: 'a', goal: 'A' }), 1)
    roster = roster.reconcile([{ subagent_id: 'b', goal: 'B', status: 'running', started_at: 100, last_tool: 'read_file' }])
    expect(roster.runs.map((run) => run.id)).toEqual(['b'])
    expect(roster.runs[0]).toMatchObject({ startedAt: 100_000, activity: [{ kind: 'tool', text: 'Read File' }] })
    expect(roster.reconcile([{ subagent_id: 'b', goal: 'B', status: 'running', started_at: 100, last_tool: 'read_file' }])).toBe(roster)
  })

  test('statuses follow Desktop and a fallback id is built from parent, index and goal', () => {
    const roster = SubagentRoster.empty.apply(event('subagent.spawn_requested', { goal: 'G', task_index: 2, status: 'queued' }), 1)
    expect(roster.runs[0]).toMatchObject({ id: 'root:2:G', status: 'queued' })
    expect(toolText('web_search', '')).toBe('Web Search')
  })
})

describe('the task list', () => {
  const todoRow = (id: string, result: unknown, phase: 'complete' | 'failed' = 'complete'): TranscriptItem => ({
    ...makeItem(id, 'tool', ''), toolName: 'todo', tool: { toolID: id, name: 'todo', phase, result: result as JSONValue },
  })
  const plan = (statuses: string[]) => ({
    todos: statuses.map((status, index) => ({ id: index + 1, content: `Task ${index + 1}`, status })), revision: 1,
  })

  test('reads the newest Todo result; subtasks go under their parent', () => {
    const parsed = parseTodoPlan(JSON.stringify({
      todos: [{ id: 'a', content: 'Parent', status: 'completed' }, { id: 'b', content: 'Child', status: 'in_progress', parent: 'a' },
        { id: 'c', content: '', status: 'pending' }, { id: 'd', content: 'Cancelled', status: 'cancelled' }],
      revision: 3,
    }))!
    expect(parsed.items.map((item) => item.id)).toEqual(['a', 'b', 'd'])
    expect(todoRows(parsed).map((row) => [row.item.id, row.depth])).toEqual([['a', 0], ['b', 1], ['d', 0]])
    expect(todoTitle(parsed)).toBe('1/2 tasks')
    expect(parseTodoPlan({ error: 'nope' } as JSONValue)).toBeUndefined()
  })

  test('a finished list goes at the next prompt; an open one stays while a later turn runs', () => {
    const user = makeItem('u2', 'user', 'next')
    const finished = [todoRow('t', plan(['completed', 'completed']))]
    expect(todoIsFinished(currentTodoPlan(finished, false)!)).toBe(true)
    expect(currentTodoPlan([...finished, user], true)).toBeUndefined()
    const open = [todoRow('t', plan(['completed', 'pending']))]
    expect(currentTodoPlan([...open, user], true)).toBeDefined()
    expect(currentTodoPlan([...open, user], false)).toBeUndefined()
    // A steer is not a new prompt; a failed call and an empty list show nothing.
    expect(currentTodoPlan([...finished, { ...user, displayKind: 'steer' }], false)).toBeDefined()
    expect(currentTodoPlan([todoRow('t', plan(['pending']), 'failed')], true)).toBeUndefined()
    expect(currentTodoPlan([todoRow('t', { todos: [], revision: 2 })], true)).toBeUndefined()
  })
})

describe('background processes', () => {
  const row = (id: string, status: string, extra: Record<string, unknown> = {}) =>
    ({ session_id: id, status, command: `sleep 5 && echo ${id}\nsecond line`, ...extra }) as JSONValue

  test('rows keep their place, report what finished, and a dismissed one never comes back', () => {
    let list = BackgroundProcessList.empty
    let read = list.reconcile([row('p1', 'running'), row('p2', 'running')])
    list = read.list
    expect(list.processes.map((process) => process.title)).toEqual(['sleep 5 && echo p1', 'sleep 5 && echo p2'])
    read = list.reconcile([row('p3', 'running'), row('p2', 'exited', { exit_code: 1, output_tail: 'a\nb\nc\nd' }), row('p1', 'running')])
    list = read.list
    expect(list.processes.map((process) => process.id)).toEqual(['p1', 'p2', 'p3'])
    expect(read.finished.map((process) => process.state)).toEqual(['failed'])
    expect(backgroundAlertBody(read.finished[0]!)).toBe('sleep 5 && echo p2 (exit 1)\nb\nc\nd')
    list = list.dismiss('p2')
    list = list.reconcile([row('p2', 'exited', { exit_code: 1 }), row('p1', 'running')]).list
    expect(list.processes.map((process) => process.id)).toEqual(['p1'])
    expect(BackgroundProcessList.lingerMs({ id: 'x', title: 'x', state: 'done' })).toBe(4000)
  })
})

describe('the alert gate', () => {
  const alert = (change: Partial<GatewayAlert>): GatewayAlert =>
    ({ kind: 'turnDone', title: 't', body: 'b', isBotChat: false, isActiveChat: true, isOnScreen: true, sessionID: 's', ...change })

  test('turns notify for the active chat while away, or off screen with banners on', () => {
    const gate = new AlertGate(defaultAlertPreferences)
    expect(gate.admit(alert({}), true, 0)).toBe(false)
    expect(gate.admit(alert({}), false, 0)).toBe(true)
    // Throttled for a second, per kind and chat.
    expect(gate.admit(alert({}), false, 500)).toBe(false)
    expect(gate.admit(alert({}), false, 1500)).toBe(true)
    expect(gate.admit(alert({ isActiveChat: false, isOnScreen: false, sessionID: 'other' }), false, 0)).toBe(false)
    expect(gate.admit(alert({ isActiveChat: false, isOnScreen: false, sessionID: 'other' }), true, 0)).toBe(true)
    gate.preferences = { ...defaultAlertPreferences, showsInApp: false }
    expect(gate.admit(alert({ isActiveChat: false, isOnScreen: false, sessionID: 'third' }), true, 0)).toBe(false)
  })

  test('approvals show off screen even in front; credits only while away; switched-off kinds never', () => {
    const gate = new AlertGate(defaultAlertPreferences)
    expect(gate.admit(alert({ kind: 'approval', isOnScreen: false }), true, 0)).toBe(true)
    expect(gate.admit(alert({ kind: 'approval', sessionID: 'x' }), true, 0)).toBe(false)
    expect(gate.admit(alert({ kind: 'credits' }), true, 0)).toBe(false)
    expect(gate.admit(alert({ kind: 'credits' }), false, 0)).toBe(true)
    gate.preferences = setAlertOn(defaultAlertPreferences, 'approval', false)
    expect(gate.admit(alert({ kind: 'approval', isOnScreen: false, sessionID: 'y' }), false, 0)).toBe(false)
  })

  test('a body is the reply trimmed to 140 characters, else the fallback', () => {
    expect(alertBody('  ')).toBe('Message complete.')
    expect(alertBody('x'.repeat(200))).toHaveLength(140)
  })
})

describe('a connected chat', () => {
  afterEach(() => vi.useRealTimers())

  /** A gateway that also answers the background methods. */
  async function setUp(extra: Record<string, (params: Record<string, unknown>) => unknown>) {
    const server = new PagedServer()
    const connection = await server.connect()
    const alerts: GatewayAlert[] = []
    connection.alerts.sink = (alert) => { alerts.push(alert); return true }
    const socket = server.socket
    const base = socket.respond!
    socket.respond = (frame) => {
      const method = frame.method as string
      if (frame.id !== undefined && extra[method]) {
        return { jsonrpc: '2.0', id: frame.id, result: extra[method]!((frame.params ?? {}) as Record<string, unknown>) }
      }
      return base(frame)
    }
    const chat = await connection.chats.openSession('default', { id: 'stored-1', title: 'Earlier' })
    return { server, connection, chat, alerts }
  }

  test('subagent events go to the roster, not the transcript; Stop clears them', async () => {
    const { server, chat } = await setUp({})
    const before = chat.get().items.length
    server.event('subagent.start', chat.sessionID, undefined, { subagent_id: 'a', goal: 'Look around' })
    await eventually(() => chat.activity.get().subagents.live.length === 1)
    expect(chat.get().items).toHaveLength(before)
    await chat.interrupt()
    expect(chat.activity.get().subagents.runs).toHaveLength(0)
  })

  test('steer and stop call the gateway with the child id', async () => {
    const { server, chat } = await setUp({
      'subagent.steer': () => ({ status: 'queued', subagent_id: 'a', text: 'x' }),
      'subagent.interrupt': () => ({ found: true, subagent_id: 'a' }),
    })
    expect(await chat.activity.steerSubagent('a', '  look at main.ts ')).toBe(true)
    expect(server.calls('subagent.steer')[0]).toMatchObject({ session_id: chat.sessionID, subagent_id: 'a', text: 'look at main.ts' })
    expect(await chat.activity.stopSubagent('a')).toBe(true)
  })

  test('a terminal tool reads the processes; one that finished notifies and goes after a while', async () => {
    let status = 'running'
    const { server, connection, chat, alerts } = await setUp({
      'process.list': () => ({ processes: [{ session_id: 'p1', status, command: 'npm test', exit_code: status === 'exited' ? 0 : null }] }),
    })
    await (connection as GatewayConnection & { settled(): Promise<void> }).settled()
    server.event('tool.complete', chat.sessionID, undefined, { tool_id: 't1', name: 'terminal' })
    await eventually(() => chat.activity.get().processes.running.length === 1)
    status = 'exited'
    await chat.activity.refreshBackgroundProcesses()
    expect(chat.activity.get().processes.processes[0]?.state).toBe('done')
    // The quiet window after connecting holds live alerts only, not this one.
    expect(alerts.map((alert) => [alert.kind, alert.title, alert.body, alert.subtitle])).toEqual([
      ['backgroundDone', 'Background task finished', 'npm test (exit 0)', 'Earlier'],
    ])
    chat.activity.dismissBackgroundProcess('p1')
    expect(chat.activity.get().processes.processes).toHaveLength(0)
  })

  test('watch reads both rosters now and polls while something runs', async () => {
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] })
    const { server, chat } = await setUp({
      'process.list': () => ({ processes: [{ session_id: 'p1', status: 'running', command: 'sleep 60' }] }),
      'subagent.list': () => ({ subagents: [] }),
    })
    const stop = chat.activity.watch()
    const again = chat.activity.watch()
    await eventually(() => chat.activity.get().processes.running.length === 1 && server.calls('subagent.list').length === 1)
    vi.advanceTimersByTime(5000)
    await eventually(() => server.calls('process.list').length === 2)
    expect(server.calls('subagent.list')).toHaveLength(1)
    stop()
    again()
    vi.advanceTimersByTime(10_000)
    expect(server.calls('process.list')).toHaveLength(2)
  })

  test('live alerts wait out the quiet window, then name the chat; approvals carry their request id', async () => {
    let now = 0
    const { server, connection, chat, alerts } = await setUp({})
    const quiet = new ConnectionAlerts({
      get client() { return undefined }, get active() { return connection.chats.active }, warm: [], bots: [],
      sessionRow: () => undefined, otherRequests: [], dropOtherRequest: () => {},
    }, () => now)
    const seen: GatewayAlert[] = []
    quiet.sink = (alert) => { seen.push(alert); return true }
    quiet.connected()
    const complete = { kind: 'event' as const, event: { type: 'message.complete', session_id: chat.sessionID, payload: { text: 'Done!' } } }
    quiet.handle(complete)
    expect(seen).toHaveLength(0)
    now = 5000
    quiet.handle(complete)
    expect(seen[0]).toMatchObject({ kind: 'turnDone', title: 'Hermes finished', body: 'Done!', subtitle: 'Earlier', isActiveChat: true,
      storedSessionID: 'stored-1', profile: 'default' })
    // The connection's own alerts, past its quiet window: an approval for the chat on screen.
    ;(connection.alerts as unknown as { quietUntil: number }).quietUntil = 0
    server.request('r1', 'approval', { session_id: chat.sessionID, request_id: 'q1', command: 'rm -rf build' })
    await eventually(() => alerts.length === 1)
    expect(alerts[0]).toMatchObject({ kind: 'approval', body: 'rm -rf build', requestID: 'r1', isOnScreen: true })
    connection.alerts.answerApproval('r1', 'once')
    expect(chat.get().pendingRequests).toHaveLength(0)
    expect(server.socket.sent.at(-1)).toMatchObject({ id: 'r1', result: { choice: 'once' } })
  })
})
