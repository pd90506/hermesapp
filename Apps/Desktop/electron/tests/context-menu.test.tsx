import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { MenuOutcome } from '../src/shared/bridge.ts'
import { useContextMenu, type ContextMenuEntry } from '../src/renderer/ui/ContextMenu.tsx'

const entries: ContextMenuEntry[] = [
  { kind: 'item', id: 'pin', label: 'Pin', icon: 'pin' },
  { kind: 'item', id: 'rename', label: 'Rename…', disabled: true },
  { kind: 'separator' },
  { kind: 'item', id: 'delete', label: 'Delete…', destructive: true },
]

function Row({ onSelect }: { onSelect: (id: string) => void }) {
  const menu = useContextMenu(() => entries, onSelect)
  return <div onContextMenu={menu.onContextMenu}>row{menu.menu}</div>
}

function withBridge(outcome: MenuOutcome) {
  const popup = vi.fn(async (..._args: unknown[]) => outcome)
  ;(window as unknown as { talaria: unknown }).talaria = { menu: { popup } }
  return popup
}

afterEach(() => {
  cleanup()
  delete (window as unknown as { talaria?: unknown }).talaria
})

describe('useContextMenu', () => {
  it('takes the pick of the system menu (macOS)', async () => {
    const popup = withBridge({ kind: 'chosen', id: 'delete' })
    const onSelect = vi.fn()
    render(<Row onSelect={onSelect} />)
    await act(async () => { fireEvent.contextMenu(screen.getByText('row'), { clientX: 10, clientY: 20 }) })
    expect(popup).toHaveBeenCalledWith([
      { kind: 'item', id: 'pin', label: 'Pin' },
      { kind: 'item', id: 'rename', label: 'Rename…', disabled: true },
      { kind: 'separator' },
      { kind: 'item', id: 'delete', label: 'Delete…', destructive: true },
    ], 10, 20)
    expect(onSelect).toHaveBeenCalledWith('delete')
    expect(screen.queryByRole('menu')).toBeNull()
  })

  it('draws the Fluent flyout when the main process leaves it to the page (Windows)', async () => {
    withBridge({ kind: 'inApp' })
    const onSelect = vi.fn()
    render(<Row onSelect={onSelect} />)
    await act(async () => { fireEvent.contextMenu(screen.getByText('row')) })
    const items = screen.getAllByRole('menuitem')
    expect(items.map((item) => item.lastElementChild?.textContent)).toEqual(['Pin', 'Rename…', 'Delete…'])
    expect(screen.getAllByRole('separator')).toHaveLength(1)
    expect((items[1] as HTMLButtonElement).disabled).toBe(true)
    expect(document.activeElement).toBe(items[0])
    // Arrow keys skip the disabled item.
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'ArrowDown' })
    expect(document.activeElement).toBe(items[2])
    fireEvent.click(items[2]!)
    expect(onSelect).toHaveBeenCalledWith('delete')
    expect(screen.queryByRole('menu')).toBeNull()
  })

  it('closes on Escape without a pick', async () => {
    withBridge({ kind: 'inApp' })
    const onSelect = vi.fn()
    render(<Row onSelect={onSelect} />)
    await act(async () => { fireEvent.contextMenu(screen.getByText('row')) })
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'Escape' })
    expect(screen.queryByRole('menu')).toBeNull()
    expect(onSelect).not.toHaveBeenCalled()
  })
})

describe('useContextMenu submenus and toggles', () => {
  const nested: ContextMenuEntry[] = [
    { kind: 'item', id: 'run', label: 'Run Now' },
    { kind: 'submenu', id: 'deliver', label: 'Deliver To', entries: [
      { kind: 'item', id: 'deliver:bot', label: 'Bot Chat', checked: true },
      { kind: 'item', id: 'deliver:local', label: 'Local', checked: false },
    ] },
  ]

  function Job({ onSelect }: { onSelect: (id: string) => void }) {
    const menu = useContextMenu(() => nested, onSelect)
    return <div onContextMenu={menu.onContextMenu}>job{menu.menu}</div>
  }

  it('sends the system menu its submenu and toggles (macOS)', async () => {
    const popup = withBridge({ kind: 'chosen', id: 'deliver:local' })
    const onSelect = vi.fn()
    render(<Job onSelect={onSelect} />)
    await act(async () => { fireEvent.contextMenu(screen.getByText('job')) })
    expect(popup.mock.calls[0]![0]).toEqual([
      { kind: 'item', id: 'run', label: 'Run Now' },
      { kind: 'submenu', id: 'deliver', label: 'Deliver To', entries: [
        { kind: 'item', id: 'deliver:bot', label: 'Bot Chat', checked: true },
        { kind: 'item', id: 'deliver:local', label: 'Local', checked: false },
      ] },
    ])
    expect(onSelect).toHaveBeenCalledWith('deliver:local')
  })

  it('opens a submenu beside its item with → and picks inside it (Windows)', async () => {
    withBridge({ kind: 'inApp' })
    const onSelect = vi.fn()
    render(<Job onSelect={onSelect} />)
    await act(async () => { fireEvent.contextMenu(screen.getByText('job')) })
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'ArrowDown' })
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'ArrowRight' })
    const menus = screen.getAllByRole('menu')
    expect(menus).toHaveLength(2)
    const toggles = screen.getAllByRole('menuitemcheckbox')
    expect(toggles.map((toggle) => toggle.getAttribute('aria-checked'))).toEqual(['true', 'false'])
    expect(document.activeElement).toBe(toggles[0])
    fireEvent.keyDown(menus[1]!, { key: 'ArrowLeft' })
    expect(screen.getAllByRole('menu')).toHaveLength(1)
    fireEvent.click(screen.getByText('Deliver To'))
    fireEvent.click(screen.getByText('Local'))
    expect(onSelect).toHaveBeenCalledWith('deliver:local')
    expect(screen.queryByRole('menu')).toBeNull()
  })
})
