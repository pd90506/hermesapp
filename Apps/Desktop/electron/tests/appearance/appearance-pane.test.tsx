import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import type { AppearanceMode } from '@talaria/hermes-core'
import type { SavedSettings } from '../../src/shared/bridge.ts'
import { AppearanceStore } from '../../src/renderer/features/settings/appearance/appearance-store.ts'
import { AppearanceForm } from '../../src/renderer/features/settings/appearance/AppearancePane.tsx'

function makeStore(saved: SavedSettings = {}) {
  const modes: AppearanceMode[] = []
  const saves: Partial<SavedSettings>[] = []
  const root = document.createElement('html')
  const store = new AppearanceStore(
    { theme: { setMode: (mode) => modes.push(mode) } },
    async (change) => { saves.push(change) },
    () => root,
  )
  store.restore(saved)
  return { store, modes, saves, root }
}

afterEach(cleanup)

describe('AppearanceStore', () => {
  it('starts on Nous, the system look and no custom sizes', () => {
    const { store, modes, root } = makeStore()
    expect(store.get().colors.preset).toBe('nous')
    expect(root.dataset.theme).toBe('nous')
    expect(modes).toEqual(['system'])
    expect(root.style.getPropertyValue('--text-ui')).toBe('')
  })

  it('applies what was saved before the window draws', () => {
    const { root, modes } = makeStore({
      appearance: { theme: 'dark', sizes: { content: 16 } },
      markdownColors: { preset: 'claudeCode', colors: {} },
    })
    expect(root.dataset.theme).toBe('claudeCode')
    expect(modes).toEqual(['dark'])
    expect(root.style.getPropertyValue('--text-content-size')).toBe('16')
  })

  it('saves in HermesKit shapes', () => {
    const { store, saves } = makeStore()
    store.setTheme('everforest')
    store.setSize('code', 13)
    expect(saves.at(-1)).toEqual({
      appearance: { theme: 'system', sizes: { code: 13 } },
      markdownColors: { preset: 'everforest', colors: {} },
    })
  })

  it('Restore Defaults keeps the theme', () => {
    const { store, root } = makeStore()
    store.setTheme('solarized')
    store.setMode('light')
    store.setSize('ui', 16)
    store.restoreDefaults()
    expect(store.get().settings.isDefault).toBe(true)
    expect(root.dataset.theme).toBe('solarized')
    expect(root.style.getPropertyValue('--text-ui')).toBe('')
  })
})

describe('Appearance pane', () => {
  it('picks the look, the theme and sizes, as the Mac pane', () => {
    const { store, modes, root } = makeStore()
    render(<AppearanceForm store={store} />)
    act(() => { fireEvent.click(screen.getByRole('radio', { name: 'Dark' })) })
    expect(modes.at(-1)).toBe('dark')
    act(() => { fireEvent.click(screen.getByRole('radio', { name: 'Catppuccin' })) })
    expect(root.dataset.theme).toBe('catppuccin')
    expect(screen.getByRole('radio', { name: 'Catppuccin' }).getAttribute('aria-checked')).toBe('true')
    expect(screen.getAllByRole('radio').map((radio) => radio.getAttribute('aria-label') ?? radio.textContent)).toEqual([
      'System', 'Light', 'Dark', 'Nous', 'GitHub', 'Catppuccin', 'Everforest', 'Solarized', 'Codex', 'Claude Code', 'System',
    ])
    act(() => { fireEvent.click(screen.getByRole('button', { name: 'Larger Code text' })) })
    expect(root.style.getPropertyValue('--text-code-size')).toBe('13')
    const field = screen.getByRole('textbox', { name: 'UI text' }) as HTMLInputElement
    act(() => {
      fireEvent.change(field, { target: { value: '40' } })
      fireEvent.blur(field)
    })
    expect(field.value).toBe('32')
  })

  it('Restore Defaults is off until something changes', () => {
    const { store } = makeStore()
    render(<AppearanceForm store={store} />)
    const restore = screen.getByRole('button', { name: 'Restore Defaults' }) as HTMLButtonElement
    expect(restore.disabled).toBe(true)
    act(() => { fireEvent.click(screen.getByRole('radio', { name: 'Light' })) })
    expect(restore.disabled).toBe(false)
    act(() => { fireEvent.click(restore) })
    expect(restore.disabled).toBe(true)
  })
})
