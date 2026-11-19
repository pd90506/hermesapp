import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Bot, Observable, SessionSidebar, type ConnectionSnapshot, type GatewayConnection, type LiveChatStatus } from '@talaria/hermes-core'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel, AppSnapshot } from '../src/renderer/app/model.ts'
import { SessionList, rowMenu } from '../src/renderer/features/sidebar/SessionList.tsx'

class Store<T> extends Observable<T> {
  put(value: T): void { this.set(value) }
}

const minute = 60_000

function renderList(snapshot: Partial<ConnectionSnapshot>) {
  const connection = new Store<ConnectionSnapshot>({
    link: { phase: 'connected' }, isTryingNoticeably: false, bots: [], sessions: {}, sessionListLoading: false,
    ...snapshot,
  })
  const call = vi.fn(async () => ({}))
  Object.assign(connection, { call, restoreLists: () => {}, sessionListLimit: () => undefined, refreshListsInBackground: () => {} })
  const sidebar = new SessionSidebar({
    connection: connection as unknown as GatewayConnection, rest: () => undefined, serverKey: () => 'srv', refreshIntervalMs: 0,
  })
  const app = new Store<AppSnapshot>({
    loaded: true, showsConnectPage: false, railShown: true, appearance: { dark: false }, connecting: false,
    server: { serverURL: 'srv', authMode: 'password', provider: 'basic', username: 'u' },
  })
  const model = Object.assign(app, { connection, sidebar }) as unknown as AppModel
  render(<ModelContext.Provider value={model}><SessionList /></ModelContext.Provider>)
  return { connection, sidebar, call }
}

afterEach(() => {
  cleanup()
  delete (window as unknown as { talaria?: unknown }).talaria
})

describe('SessionList', () => {
  const bot = new Bot({ name: 'default', display_name: 'Hermes', canonical_session: { id: 'bot', preview: 'Hi there' } })

  it('pins the Bot Chat above the sessions', () => {
    renderList({
      bots: [bot],
      selectedProfile: 'default',
      sessions: { default: [{ id: 's1', title: 'Plan the trip' }, { id: 's2', title: '' }] },
    })
    const headings = screen.getAllByRole('heading').map((heading) => heading.textContent)
    expect(headings).toEqual(['Bot Chat', 'Sessions'])
    expect(screen.getByText('Hermes')).toBeTruthy()
    expect(screen.getByText('Hi there')).toBeTruthy()
    expect(screen.getByText('Plan the trip')).toBeTruthy()
    expect(screen.getByText('Untitled chat')).toBeTruthy()
  })

  it('says when a profile has no sessions', () => {
    renderList({ bots: [bot], selectedProfile: 'default', sessions: { default: [] } })
    expect(screen.getByText('No sessions yet')).toBeTruthy()
  })

  it('shows loading, then the list', () => {
    const { connection } = renderList({ bots: [bot], selectedProfile: 'default', sessionListLoading: true })
    expect(screen.getByText('Loading sessions…')).toBeTruthy()
    act(() => connection.put({ ...connection.get(), sessionListLoading: false, sessions: { default: [{ id: 's1', title: 'New' }] } }))
    expect(screen.queryByText('Loading sessions…')).toBeNull()
  })

  it('lists pinned rows first, then the rest in date groups, with their ages', () => {
    const { sidebar } = renderList({
      bots: [bot], selectedProfile: 'default',
      sessions: { default: [{ id: 'a', title: 'Today', message_count: 1 }, { id: 'b', title: 'Old', message_count: 1 }, { id: 'c', title: 'Pinned one' }] },
    })
    const now = Date.now()
    act(() => {
      sidebar.setPinned(true, 'srv', 'default', 'c')
      ;(sidebar as unknown as { update(change: object): void }).update({ activity: {
        'default/a': { key: 'k', activity: { lastPrompt: now - 5 * minute } },
        'default/b': { key: 'k', activity: { lastPrompt: now - 400 * 24 * 60 * minute } },
      } })
    })
    const groups = screen.getAllByRole('group').map((group) => group.getAttribute('aria-label'))
    expect(groups[0]).toBe('Pinned')
    expect(groups[1]).toBe('Sessions')
    expect(groups).toHaveLength(3)
    expect(within(screen.getAllByRole('group')[0]!).getByText('Pinned one')).toBeTruthy()
    expect(screen.getByText('5 minutes ago')).toBeTruthy()
  })

  it('marks unread rows and shows a live chat\'s status in their place', () => {
    const { sidebar } = renderList({
      bots: [bot], selectedProfile: 'default', sessions: { default: [{ id: 'a', title: 'Answered' }, { id: 'b', title: 'Asking' }] },
    })
    const live: LiveChatStatus = {
      status: (_profile, id) => id === 'b' ? 'waitingForYou' : 'idle',
      botChatStatus: () => 'idle', waitingChats: () => [], subscribe: () => () => {},
    }
    act(() => {
      ;(sidebar as unknown as { update(change: object): void }).update({
        readMarks: sidebar.get().readMarks.start(1),
        activity: { 'default/a': { key: 'k', activity: { newestReply: Date.now() } } },
      })
      sidebar.setLiveStatus(live)
    })
    expect(screen.getByLabelText('Unread')).toBeTruthy()
    expect(screen.getByText('Waiting for your answer')).toBeTruthy()
    // Selecting it makes it seen.
    fireEvent.click(screen.getByText('Answered'))
    expect(screen.queryByLabelText('Unread')).toBeNull()
  })

  it('archives from the row menu over JSON-RPC', async () => {
    const { call } = renderList({ bots: [bot], selectedProfile: 'default', sessions: { default: [{ id: 'a', title: 'Done' }] } })
    await act(async () => { fireEvent.click(screen.getByLabelText('More actions')) })
    await act(async () => { fireEvent.click(screen.getByRole('menuitem', { name: 'Archive' })) })
    expect(call).toHaveBeenCalledWith('session.archive', { session_id: 'a', archived: true, profile: 'default' })
  })

  it('asks before deleting', async () => {
    const { call } = renderList({ bots: [bot], selectedProfile: 'default', sessions: { default: [{ id: 'a', title: 'Done' }] } })
    await act(async () => { fireEvent.contextMenu(screen.getByText('Done')) })
    await act(async () => { fireEvent.click(screen.getByRole('menuitem', { name: 'Delete…' })) })
    expect(screen.getByText('Delete “Done”?')).toBeTruthy()
    expect(call).not.toHaveBeenCalled()
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Delete' })) })
    expect(call).toHaveBeenCalledWith('session.delete', { session_id: 'a', profile: 'default' })
  })

  it('has the Mac\'s row actions, Pin alone offline', () => {
    expect(rowMenu(false, false).map((entry) => entry.kind === 'separator' ? '—' : `${entry.label}${entry.disabled ? ' (off)' : ''}`))
      .toEqual(['Pin', 'Rename… (off)', 'Fork (off)', 'Archive (off)', '—', 'Delete… (off)'])
    expect(rowMenu(true, true).map((entry) => entry.kind === 'separator' ? '—' : entry.label)[0]).toBe('Unpin')
  })
})
