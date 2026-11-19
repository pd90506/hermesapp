import { GatewayClientError } from '../../client.ts'
import { describeError } from '../../describe.ts'
import { RPCError, type JSONValue } from '../../protocol/jsonrpc.ts'
import type { ChatSession } from '../../session/chat-session.ts'
import { SlashCatalog, parseSlashCommand, slashClientActions } from './slash-commands.ts'

/** What running a slash command did (HermesKit's `SlashOutcome`). */
export type SlashOutcome =
  /** Text output, also appended to the transcript as a system row. */
  | { kind: 'output'; text: string }
  /** A prompt was submitted (a skill, a bundle, a command that composes one); `display` is what the bubble shows. */
  | { kind: 'submitted'; display: string }
  /** Put this text into the composer for editing (e.g. `/undo`). */
  | { kind: 'prefill'; text: string }
  /** Handled here (`/btw`, `/bg`, `/title`); the transcript shows the effect. */
  | { kind: 'handled' }
  /** A Desktop client-side action or picker (`/new`, `/model`, …) the composer carries out; nothing was sent. */
  | { kind: 'clientAction'; name: string; argument: string }
  /** The command cannot run from this app; nothing was sent. */
  | { kind: 'unavailable'; reason: string }

/** The slash catalog as the composer holds it. */
export interface SlashCatalogSource {
  readonly catalog: SlashCatalog | undefined
  load(): Promise<SlashCatalog>
}

const record = (value: unknown): Record<string, JSONValue> | undefined =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, JSONValue> : undefined
const nonEmpty = (value: unknown): string | undefined =>
  typeof value === 'string' && value.trim() !== '' ? value : undefined

function note(session: ChatSession, text: string): SlashOutcome {
  session.appendLocalNote(text)
  return { kind: 'output', text }
}

/**
 * Runs a slash command typed in the composer, following Desktop's routing
 * (`use-prompt-actions/slash.ts:262-464,1332-1389`, HermesKit's `ChatSession.runSlash`):
 * - in a Bot Chat, `/new`, `/reset` and `/clear` compress instead: the bot's chat never
 *   restarts (`plugins/hermes-bots/plugin.tsx:765-800`);
 * - commands that are a plain RPC run here: `/btw`, `/bg`, `/compress`, `/save`,
 *   `/status`, `/title`, `/stop`;
 * - Desktop's client-side actions and pickers come back as `clientAction`;
 * - the rest goes to the gateway after the catalog's gate (loaded first if needed; a
 *   failed load throws): `slash.exec`, and on any error `command.dispatch`. A skill is sent
 *   as a normal prompt whose bubble shows the invocation.
 */
export async function runSlash(session: ChatSession, value: string, catalogs: SlashCatalogSource, depth = 0): Promise<SlashOutcome> {
  const { name: typed, argument } = parseSlashCommand(value)
  if (typed === '') return { kind: 'unavailable', reason: 'Type a command after /.' }
  const known = catalogs.catalog?.canonicalName(typed).slice(1)
  const isOne = (...names: string[]): boolean => names.includes(typed) || (known !== undefined && names.includes(known))

  if (session.kind === 'botChat' && isOne('new', 'reset', 'clear')) {
    session.appendLocalNote('Bot chats are one continuous conversation — compacting instead.')
    return { kind: 'output', text: await session.compress() }
  }
  if (isOne('btw')) {
    if (argument === '') return note(session, 'Usage: /btw <question>')
    const client = await session.liveClient()
    const answer = record(await client.call('prompt.btw', { session_id: session.sessionID, text: argument }))
    session.beginSideQuestion(String(answer?.task_id ?? ''), argument, 'btw')
    return { kind: 'handled' }
  }
  if (isOne('bg', 'background')) {
    if (argument === '') return note(session, 'Usage: /background <prompt> — the result appears here when done.')
    const client = await session.liveClient()
    const answer = record(await client.call('prompt.background', { session_id: session.sessionID, text: argument }))
    session.beginSideQuestion(String(answer?.task_id ?? ''), argument, 'background')
    return { kind: 'handled' }
  }
  if (isOne('compress', 'compact')) return { kind: 'output', text: await session.compress(argument) }
  if (isOne('save')) {
    const client = await session.liveClient()
    const file = nonEmpty(record(await client.call('session.save', { session_id: session.sessionID }))?.file)
    return note(session, file ? `Saved transcript to ${file}` : 'Saved transcript.')
  }
  if (isOne('status')) {
    const client = await session.liveClient()
    const output = record(await client.call('session.status', { session_id: session.sessionID }))?.output
    return note(session, typeof output === 'string' ? output : '(no output)')
  }
  if (isOne('title')) {
    if (argument === '') return note(session, `Title: ${session.title ?? 'untitled'}`)
    const client = await session.liveClient()
    await client.call('session.title', { session_id: session.sessionID, title: argument })
    session.setTitle(argument)
    return note(session, `Renamed to ${argument}.`)
  }
  if (isOne('stop')) {
    // Desktop's `/stop` (`slash.ts:525-570`): the running turn, then every background process.
    const lines: string[] = []
    try {
      await session.interrupt()
      lines.push('Stopped the active turn.')
    } catch (error) {
      lines.push(`Could not stop the active turn: ${describeError(error)}`)
    }
    try {
      const client = await session.liveClient()
      const killed = Number(record(await client.call('process.stop', {}))?.killed ?? 0)
      lines.push(killed > 0 ? `Stopped ${killed} background process${killed === 1 ? '' : 'es'}.` : 'No background processes to stop.')
    } catch (error) {
      lines.push(`Could not stop background processes: ${describeError(error)}`)
    }
    return note(session, lines.join('\n'))
  }
  if ([...slashClientActions].some((action) => isOne(action))) {
    // The canonical name when the typed one is an alias the catalog knows.
    const name = known !== undefined && slashClientActions.has(known) ? known : typed
    return { kind: 'clientAction', name, argument }
  }

  // Gateway-bound: gate on the catalog, loading it if this chat has none.
  const catalog = catalogs.catalog ?? await catalogs.load()
  const refusal = catalog.refusal(typed, argument)
  if (refusal !== undefined) return { kind: 'unavailable', reason: refusal }
  const name = catalog.canonicalName(typed).slice(1)
  const client = await session.liveClient()
  let result: Record<string, JSONValue>
  try {
    result = record(await client.call('slash.exec', { session_id: session.sessionID, command: argument === '' ? name : `${name} ${argument}` })) ?? {}
  } catch (execError) {
    // Skills, quick commands and anything the worker refused (`slash.ts:430-463`).
    try {
      const params: Record<string, JSONValue> = { name, session_id: session.sessionID }
      if (argument !== '') params.arg = argument
      result = record(await client.call('command.dispatch', params)) ?? {}
    } catch (dispatchError) {
      // The fallback had nothing to add: the worker's failure is the real error.
      if (dispatchError instanceof RPCError && /not a quick\/plugin\/(bundle\/)?skill command/i.test(dispatchError.message)) throw execError
      throw dispatchError
    }
  }
  const type = typeof result.type === 'string' ? result.type : undefined
  if (type === undefined) {
    let output = typeof result.output === 'string' ? result.output : ''
    if (nonEmpty(result.warning)) output = `warning: ${result.warning as string}\n${output}`
    return note(session, output === '' ? '(no output)' : output)
  }
  if (type === 'exec' || type === 'plugin') return note(session, typeof result.output === 'string' ? result.output : '(no output)')
  if (type === 'alias') {
    const target = nonEmpty(result.target)
    if (!target || depth >= 3) return note(session, `/${name}: bad alias`)
    return runSlash(session, `/${target}${argument === '' ? '' : ` ${argument}`}`, catalogs, depth + 1)
  }
  const notice = nonEmpty(result.notice)?.trim()
  if (notice && (type === 'send' || type === 'prefill')) session.appendLocalNote(notice)
  const message = (typeof result.message === 'string' ? result.message : '').trim()
  if (type === 'prefill') return { kind: 'prefill', text: message }
  if (type !== 'send' && type !== 'skill') return note(session, `/${name}: unsupported result ${type}`)
  if (message === '') return note(session, `/${name}: ${type === 'skill' ? 'skill payload missing message' : 'empty message'}`)
  // Show the invocation, never the expanded skill body.
  const display = nonEmpty(result.display)?.trim() ?? (argument === '' ? `/${name}` : `/${name} ${argument}`)
  await session.send(message, undefined, display)
  return { kind: 'submitted', display }
}

/** A lost or missing connection, which a reconnect may fix (HermesKit's `GatewayConnection.isLinkFailure`). */
export function isLinkFailure(error: unknown): boolean {
  return error instanceof GatewayClientError &&
    ['notConnected', 'connectionClosed', 'readyTimeout', 'heartbeatTimeout', 'timeout'].includes(error.kind)
}
