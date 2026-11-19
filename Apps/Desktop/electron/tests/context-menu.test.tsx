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
  const popup = vi.fn(async () => outcome)
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
