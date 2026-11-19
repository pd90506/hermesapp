import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
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

afterEach(cleanup)

describe('useContextMenu', () => {
  it('draws the menu at the pointer and takes a pick', async () => {
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

  it('opens a submenu beside its item with → and picks inside it', async () => {
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
