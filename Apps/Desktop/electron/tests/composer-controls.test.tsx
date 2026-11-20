import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { Observable } from '@talaria/hermes-core'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel } from '../src/renderer/app/model.ts'
import { ChatPane } from '../src/renderer/features/chat/ChatPane.tsx'
import { PagedServer, eventually } from '../../../../Packages/hermes-core/tests/support/paged-server.ts'

// Package D: the model and effort pills, the slash list and the context gauge, in the
// composer A draws (registered through features/composer/registered-slots.ts).

class NoResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
const sizes = ['offsetHeight', 'offsetWidth', 'clientHeight', 'clientWidth'] as const
beforeAll(() => {
  Object.assign(window, { ResizeObserver: NoResizeObserver })
  for (const name of sizes) {
    Object.defineProperty(HTMLElement.prototype, name, { configurable: true, get: () => name.endsWith('Width') ? 800 : 100 })
  }
})
afterEach(cleanup)

function serverWithComposer(): { server: PagedServer; sets: Array<Record<string, unknown>> } {
  const server = new PagedServer()
  const sets: Array<Record<string, unknown>> = []
  server.handlers.set('model.options', () => ({
    model: 'test-model', provider: 'local',
    providers: [
      { slug: 'local', name: 'Local', models: ['test-model', 'claude-opus-5-5'],
        capabilities: { 'test-model': { reasoning: true }, 'claude-opus-5-5': { reasoning: true, can_disable_reasoning: false } } },
      { slug: 'cloud', name: 'Cloud', models: ['gpt-5.2'] },
    ],
  }))
  server.handlers.set('config.get', () => ({ value: 'medium' }))
  server.handlers.set('config.set', (params) => {
    sets.push(params)
    if (params.key === 'model' && String(params.value).startsWith('gpt-5.2') && !params.confirm_expensive_model) {
      return { confirm_required: true, confirm_message: 'GPT-5.2 costs more per token.' }
    }
    return { key: params.key, value: params.key === 'reasoning' ? params.value : 'ok' }
  })
  server.handlers.set('commands.catalog', () => ({
    categories: [{ name: 'Session', pairs: [['/compress', 'Compress this conversation context'], ['/status', 'Show session status']] }],
    pairs: [['/compress', 'Compress this conversation context'], ['/status', 'Show session status']],
    commands: { '/compress': { argument_mode: 'text' } },
  }))
  server.handlers.set('complete.slash', (params) => ({
    items: ['compress', 'status'].filter((name) => `/${name}`.startsWith(String(params.text))).map((name) => ({ text: name })),
    replace_from: 1,
  }))
  server.handlers.set('session.usage', () => ({ total: 4200, input: 4000, output: 200, calls: 3, context_used: 50_000, context_max: 200_000, context_percent: 25 }))
  server.handlers.set('session.context_breakdown', () => ({ context_max: 0 }))
  server.handlers.set('session.status', () => ({ output: 'All good.' }))
  return { server, sets }
}

async function openChat(server: PagedServer) {
  const connection = await server.connect()
  const model = Object.assign(new Observable({}), { connection }) as unknown as AppModel
  render(<ModelContext.Provider value={model}><ChatPane /></ModelContext.Provider>)
  await act(async () => { await connection.chats.openBotChat('coder') })
  return connection
}

describe('composer controls', () => {
  it('shows the model and effort, switches the model for this chat, and asks before an expensive one', async () => {
    const { server, sets } = serverWithComposer()
    await openChat(server)
    const pill = await screen.findByRole('button', { name: 'Model' })
    expect(await eventually(() => pill.textContent === 'Test Model')).toBe(true)
    expect(screen.getByRole('button', { name: 'Reasoning effort' }).textContent).toBe('Medium')

    fireEvent.click(pill)
    const menu = screen.getByRole('menu', { name: 'Model' })
    expect([...menu.querySelectorAll('[role="group"]')].map((group) => group.getAttribute('aria-label'))).toEqual(['Cloud', 'Local'])
    expect(screen.getByRole('menuitemradio', { name: 'Test Model' }).getAttribute('aria-checked')).toBe('true')
    expect(screen.getByRole('menuitem', { name: 'Reload Models' })).toBeTruthy()

    fireEvent.click(screen.getByRole('menuitemradio', { name: 'Opus 5.5' }))
    expect(screen.queryByRole('menu')).toBeNull()
    expect(await eventually(() => pill.textContent === 'Opus 5.5')).toBe(true)
    expect(sets.at(-1)).toMatchObject({ key: 'model', value: 'claude-opus-5-5 --provider local --session' })
    // Opus can't turn thinking off: no "Off" in its effort menu.
    fireEvent.click(screen.getByRole('button', { name: 'Reasoning effort' }))
    expect(screen.queryByRole('menuitemradio', { name: 'Off' })).toBeNull()
    fireEvent.click(screen.getByRole('menuitemradio', { name: 'High' }))
    expect(await eventually(() => screen.getByRole('button', { name: 'Reasoning effort' }).textContent === 'High')).toBe(true)

    fireEvent.click(pill)
    fireEvent.click(screen.getByRole('menuitemradio', { name: 'GPT-5.2' }))
    const dialog = await screen.findByRole('alertdialog')
    expect(dialog.textContent).toContain('GPT-5.2 costs more per token.')
    fireEvent.click(screen.getByRole('button', { name: 'Keep Current Model' }))
    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(pill.textContent).toBe('Opus 5.5')
    fireEvent.click(pill)
    fireEvent.click(screen.getByRole('menuitemradio', { name: 'GPT-5.2' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Switch to GPT-5.2' }))
    expect(await eventually(() => pill.textContent === 'GPT-5.2')).toBe(true)
    expect(sets.at(-1)).toMatchObject({ key: 'model', confirm_expensive_model: true })
  })

  it('lists slash commands, moves with the arrows and runs the command on Return', async () => {
    const { server } = serverWithComposer()
    await openChat(server)
    await eventually(() => server.calls('commands.catalog').length > 0)
    const text = screen.getByLabelText('Message') as HTMLTextAreaElement
    fireEvent.change(text, { target: { value: '/' } })
    const list = await screen.findByRole('listbox', { name: 'Commands' })
    expect([...list.querySelectorAll('[role="option"]')].map((row) => row.textContent))
      .toEqual(['/compressCompress this conversation context', '/statusShow session status'])
    fireEvent.keyDown(text, { key: 'ArrowDown' })
    expect(screen.getByRole('option', { selected: true }).textContent).toContain('/status')
    fireEvent.keyDown(text, { key: 'Enter' })
    expect(text.value).toBe('/status ')
    expect(screen.queryByRole('listbox')).toBeNull()
    fireEvent.keyDown(text, { key: 'Enter' })
    expect(await eventually(() => screen.queryByText('All good.') !== null)).toBe(true)
    expect(server.calls('prompt.submit')).toEqual([])
  })

  it('says when nothing matches, and Esc clears it', async () => {
    const { server } = serverWithComposer()
    await openChat(server)
    await eventually(() => server.calls('commands.catalog').length > 0)
    const text = screen.getByLabelText('Message') as HTMLTextAreaElement
    fireEvent.change(text, { target: { value: '/zzz' } })
    expect(await eventually(() => screen.queryByText('No matches. Try /help.') !== null)).toBe(true)
    fireEvent.keyDown(text, { key: 'Escape' })
    expect(screen.queryByText('No matches. Try /help.')).toBeNull()
  })

  it('shows the context ring and its details', async () => {
    const { server } = serverWithComposer()
    await openChat(server)
    const gauge = await screen.findByRole('button', { name: 'Context' })
    expect(gauge.textContent).toBe('25%')
    expect(gauge.getAttribute('title')).toBe('Context: 50K of 200K tokens (25%)')
    fireEvent.click(gauge)
    const details = screen.getByRole('dialog', { name: 'Context details' })
    expect(details.textContent).toContain('This Session')
    expect(details.textContent).toContain('4.2K (4K in · 200 out)')
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByRole('dialog', { name: 'Context details' })).toBeNull()
  })
})
