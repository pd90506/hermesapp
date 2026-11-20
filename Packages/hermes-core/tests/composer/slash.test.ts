import { describe, expect, it } from 'vitest'
import {
  SlashCatalog, SlashCompletions, implicitAcceptIndex, isSlashCommand, isSlashCompletionCandidate, parseSlashCommand,
  slashRows, type ChatComposer,
} from '../../src/index.ts'
import { PagedServer, eventually } from '../support/paged-server.ts'

// After HermesKit's SlashCommandTests: `commands.catalog` as `methods_tools.py:503-537`
// builds it, with registry categories, "User commands", and skills only in `pairs`.
const catalogPayload = {
  pairs: [['/compress', 'Compress this conversation context'], ['/usage', 'Show token usage'], ['/model', 'Switch model'],
    ['/voice', 'Toggle voice mode'], ['/deploy', 'exec: ./deploy.sh'], ['/standup', 'Daily standup notes']],
  sub: {},
  canon: { '/compact': '/compress' },
  commands: {
    '/compress': { argument_mode: 'text', desktop: null },
    '/usage': { argument_mode: null, desktop: null },
    '/model': { argument_mode: 'options', desktop: 'hidden' },
    '/voice': { argument_mode: 'options', desktop: 'composer-voice' },
    '/skills': { argument_mode: 'options', desktop: 'advanced', desktop_subcommands: ['pending', 'approve'] },
  },
  categories: [
    { name: 'Session', pairs: [['/compress', 'Compress this conversation context'], ['/usage', 'Show token usage'], ['/model', 'Switch model']] },
    { name: 'Configuration', pairs: [['/voice', 'Toggle voice mode']] },
    { name: 'User commands', pairs: [['/deploy', 'exec: ./deploy.sh']] },
  ],
  skills: { '/standup': { usage: 3, origin: 'local' } },
  skill_count: 1,
  warning: '',
}

describe('SlashCatalog', () => {
  const catalog = new SlashCatalog(catalogPayload)

  it('lists commands, quick commands and skills', () => {
    expect(catalog.commands.map((command) => command.name)).toEqual(['/compress', '/usage', '/voice', '/deploy', '/standup'])
    expect(catalog.command('deploy')?.kind).toBe('quick')
    expect(catalog.command('/standup')).toMatchObject({ kind: 'skill', category: 'Skills' })
    expect(catalog.command('/compact')?.name).toBe('/compress')
    expect(catalog.command('/voice')?.unavailableReason).toMatch(/^Voice chat isn't available/)
    expect(catalog.command('/model')).toBeUndefined()
    expect(catalog.warning).toBeUndefined()
  })

  it('recognises and parses commands', () => {
    expect(isSlashCommand('/compress')).toBe(true)
    expect(isSlashCommand('  /btw what now?')).toBe(true)
    expect(isSlashCommand('/usr/bin/env is missing')).toBe(false)
    expect(isSlashCommand('hello /compress')).toBe(false)
    expect(parseSlashCommand('/Title  My   chat ')).toEqual({ name: 'title', argument: 'My   chat' })
    expect(isSlashCompletionCandidate('/compress more')).toBe(true)
    expect(isSlashCompletionCandidate('/usr/bin something')).toBe(false)
    expect(isSlashCompletionCandidate('/a\nb')).toBe(false)
  })

  it('applies a completion', () => {
    const command = new SlashCompletions({ items: [{ text: 'compress ' }], replace_from: 1 }, '/comp')
    expect(command.items[0]).toEqual({ text: '/compress', display: '/compress' })
    expect(command.applying(command.items[0]!)).toBe('/compress')
    const argument = new SlashCompletions({ items: [{ text: 'alice' }], replace_from: 13 }, '/personality ali')
    expect(argument.applying(argument.items[0]!)).toBe('/personality alice')
  })

  it('browses in catalog order and gates rows', () => {
    expect(catalog.suggestions('/').map((row) => row.text)).toEqual(['/compress', '/usage', '/deploy', '/standup'])
    const completions = new SlashCompletions({ items: [{ text: '/model' }, { text: '/standup', kind: 'skill' }, { text: '/compress' },
      { text: '/compact' }] }, '/co')
    expect(catalog.suggestions('/co', completions).map((row) => [row.text, row.category]))
      .toEqual([['/compress', 'Commands'], ['/standup', 'Skills']])
    // An alias only when typed exactly.
    const alias = new SlashCompletions({ items: [{ text: '/compact' }] }, '/compact')
    expect(catalog.suggestions('/compact', alias).map((row) => row.text)).toEqual(['/compact'])
    // Arguments the `desktop_subcommands` gate allows.
    const sub = new SlashCompletions({ items: [{ text: 'pending' }, { text: 'reject' }], replace_from: 8 }, '/skills ')
    expect(catalog.suggestions('/skills ', sub).map((row) => row.text)).toEqual(['/skills pending'])
  })

  it('refuses what a GUI cannot run', () => {
    expect(catalog.refusal('voice', '')).toMatch(/^Voice chat/)
    expect(catalog.refusal('skills', '')).toBe('/skills is not shown in the slash palette. Use the relevant Hermes Desktop control or the terminal interface instead.')
    expect(catalog.refusal('skills', 'reject')).toMatch(/^\/skills is not shown/)
    expect(catalog.refusal('skills', 'pending')).toBeUndefined()
    expect(catalog.refusal('compress', 'topic')).toBeUndefined()
    expect(catalog.helpText.split('\n')[0]).toBe('Available commands:')
    expect(catalog.helpText).not.toContain('/voice')
  })

  it('picks the row Return takes', () => {
    const texts = ['/compress', '/compact', '/status']
    expect(implicitAcceptIndex('/stat', texts, 0, false)).toBe(2)
    expect(implicitAcceptIndex('/comp', texts, 0, false)).toBe(0)
    expect(implicitAcceptIndex('/compa', texts, 0, false)).toBe(1)
    expect(implicitAcceptIndex('/co', texts, 2, false)).toBeUndefined()
    expect(implicitAcceptIndex('/x', texts, 2, true)).toBe(2)
    expect(implicitAcceptIndex('/', texts, 0, false)).toBeUndefined()
  })

  it('gives repeated rows their own ids and headers', () => {
    const rows = slashRows([
      { item: { text: '/a' }, category: 'Commands', text: '/a' },
      { item: { text: '/a' }, category: 'Commands', text: '/a' },
      { item: { text: '/s' }, category: 'Skills', text: '/s' },
    ], 1)
    expect(rows.map((row) => [row.id, row.header, row.isSelected])).toEqual([
      ['/a', 'Commands', false], ['/a#2', undefined, true], ['/s', 'Skills', false],
    ])
  })
})

async function openComposer(server = new PagedServer()): Promise<{ server: PagedServer; composer: ChatComposer }> {
  server.handlers.set('commands.catalog', () => catalogPayload)
  server.handlers.set('model.options', () => ({ providers: [] }))
  server.handlers.set('config.get', () => ({ value: 'medium' }))
  server.handlers.set('complete.slash', (params) => {
    const text = String(params.text)
    return { items: ['compress', 'status', 'standup'].filter((name) => `/${name}`.startsWith(text)).map((name) => ({ text: name })), replace_from: 1 }
  })
  const connection = await server.connect()
  const chat = await connection.chats.newChat('coder')
  return { server, composer: connection.chats.composer(chat) }
}

describe('ChatComposer slash commands', () => {
  it('opens, filters and accepts', async () => {
    const { server, composer } = await openComposer()
    await composer.loadCommandsAndOptions()
    composer.setDraft('/')
    expect(await eventually(() => composer.slash.get().isOpen)).toBe(true)
    expect(composer.slash.get().suggestions[0]?.text).toBe('/compress')
    composer.setDraft('/comp')
    expect(await eventually(() => composer.slash.get().suggestions.length === 1)).toBe(true)
    expect(composer.slash.handleKey('accept')).toBe(true)
    expect(composer.draft).toBe('/compress ')
    expect(composer.slash.get().isOpen).toBe(false)
    expect(server.calls('prompt.submit')).toEqual([])
  })

  it('moves with the arrows and closes with Esc until the draft changes', async () => {
    const { composer } = await openComposer()
    await composer.loadCommandsAndOptions()
    composer.setDraft('/')
    expect(await eventually(() => composer.slash.get().isOpen)).toBe(true)
    composer.slash.handleKey('down')
    expect(composer.slash.rows[1]?.isSelected).toBe(true)
    composer.slash.handleKey('up')
    composer.slash.handleKey('up')
    expect(composer.slash.rows.at(-1)?.isSelected).toBe(true)
    expect(composer.slash.handleKey('tab')).toBe(true)
    expect(composer.draft).toBe('/standup ')
    composer.setDraft('/')
    expect(await eventually(() => composer.slash.get().isOpen)).toBe(true)
    expect(composer.slash.handleKey('escape')).toBe(true)
    expect(composer.slash.get().isOpen).toBe(false)
    expect(composer.slash.handleKey('accept')).toBe(false)
  })

  it('runs a command instead of sending it, and shows the output', async () => {
    const { server, composer } = await openComposer()
    server.handlers.set('slash.exec', (params) => ({ output: `ran ${String(params.command)}` }))
    composer.setDraft('/usage')
    await composer.submit()
    expect(server.calls('slash.exec')[0]?.command).toBe('usage')
    expect(server.calls('prompt.submit')).toEqual([])
    expect(composer.session.get().items.at(-1)?.text).toBe('ran usage')
    expect(composer.draft).toBe('')
  })

  it('sends a skill as a prompt that shows its invocation', async () => {
    const { server, composer } = await openComposer()
    server.errors.set('slash.exec', { code: 4018, message: 'not a registry command' })
    server.handlers.set('command.dispatch', () => ({ type: 'skill', message: 'EXPANDED SKILL BODY', name: 'standup' }))
    server.held.add('prompt.submit')
    composer.setDraft('/standup today')
    const sent = composer.submit()
    expect(await eventually(() => server.heldFrames.length === 1)).toBe(true)
    expect(server.calls('command.dispatch')[0]).toMatchObject({ name: 'standup', arg: 'today' })
    expect(server.calls('prompt.submit')[0]?.text).toBe('EXPANDED SKILL BODY')
    expect(composer.session.get().items.filter((item) => item.role === 'user').map((item) => item.text)).toEqual(['/standup today'])
    server.answer(server.heldFrames[0]!, { status: 'streaming' })
    await sent
  })

  it('refuses GUI-less commands without sending anything', async () => {
    const { server, composer } = await openComposer()
    composer.setDraft('/voice on')
    await composer.submit()
    expect(server.calls('slash.exec')).toEqual([])
    expect(composer.session.get().items.at(-1)?.text).toMatch(/^Voice chat/)
  })

  it('compresses, and drops a second compression while one runs', async () => {
    const { server, composer } = await openComposer()
    server.held.add('session.compress')
    composer.setDraft('/compress')
    const first = composer.submit()
    expect(await eventually(() => server.heldFrames.length === 1)).toBe(true)
    expect(composer.queue.get().isCompressing).toBe(true)
    composer.setDraft('/compact')
    await composer.submit()
    expect(server.heldFrames.length).toBe(1)
    server.answer(server.heldFrames[0]!, { status: 'compressed', removed: 4, summary: { headline: 'Compressed 10 → 4 messages' } })
    await first
    expect(composer.queue.get().isCompressing).toBe(false)
    expect(composer.session.get().items.at(-1)).toMatchObject({ text: 'Compressed 10 → 4 messages', displayKind: 'compression' })
  })

  it('opens the model picker for a bare /model and answers /help locally', async () => {
    const { server, composer } = await openComposer()
    await composer.loadCommandsAndOptions()
    composer.setDraft('/model')
    await composer.submit()
    expect(composer.models.get().isPickerRequested).toBe(true)
    composer.setDraft('/help')
    await composer.submit()
    expect(composer.session.get().items.at(-1)?.text).toContain('/compress — Compress this conversation context')
    expect(server.calls('slash.exec')).toEqual([])
  })

  it('puts a failed command back into an empty draft', async () => {
    const { server, composer } = await openComposer()
    server.errors.set('session.save', { code: 5000, message: 'disk full' })
    composer.setDraft('/save')
    await composer.submit()
    expect(composer.draft).toBe('/save')
    expect(composer.session.get().items.at(-1)?.text).toBe('/save: disk full')
  })
})
