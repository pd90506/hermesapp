import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { TabBar } from '../src/renderer/features/sidebar/TabBar.tsx'
import { registerSidebarTab, resetSidebarTabs, sidebarTabs } from '../src/renderer/features/sidebar/tabs.ts'

afterEach(() => {
  cleanup()
  resetSidebarTabs()
})

describe('sidebar tabs', () => {
  it('are drawn in order, the picked one selected, an alert as a dot', () => {
    registerSidebarTab({ id: 'cron', title: 'Cron Jobs', icon: 'more', order: 10, Page: () => null, useAlert: () => true })
    registerSidebarTab({ id: 'sessions', title: 'Sessions', icon: 'sessions', order: 0, Page: () => null })
    const tabs = sidebarTabs()
    expect(tabs.map((tab) => tab.id)).toEqual(['sessions', 'cron'])
    const onSelect = vi.fn()
    render(<TabBar tabs={tabs} selected="sessions" onSelect={onSelect} />)
    const buttons = screen.getAllByRole('tab')
    expect(buttons.map((button) => button.getAttribute('aria-selected'))).toEqual(['true', 'false'])
    expect(screen.getAllByLabelText('Needs attention')).toHaveLength(1)
    fireEvent.click(buttons[1]!)
    expect(onSelect).toHaveBeenCalledWith('cron')
  })
})
