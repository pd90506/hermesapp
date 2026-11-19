import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { Bot, Observable, type ConnectionSnapshot } from '@talaria/hermes-core'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel } from '../src/renderer/app/model.ts'
import { SessionList } from '../src/renderer/features/sidebar/SessionList.tsx'

class Store<T> extends Observable<T> {
  put(value: T): void { this.set(value) }
}

function renderList(snapshot: Partial<ConnectionSnapshot>) {
  const connection = new Store<ConnectionSnapshot>({
    link: { phase: 'connected' }, isTryingNoticeably: false, bots: [], sessions: {}, sessionListLoading: false,
    ...snapshot,
  })
  const model = { connection } as unknown as AppModel
  render(<ModelContext.Provider value={model}><SessionList /></ModelContext.Provider>)
  return connection
}

afterEach(cleanup)

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
    expect(screen.getByText('Plan the trip')).toBeTruthy()
    expect(screen.getByText('Untitled chat')).toBeTruthy()
  })

  it('says when a profile has no sessions', () => {
    renderList({ bots: [bot], selectedProfile: 'default', sessions: { default: [] } })
    expect(screen.getByText('No sessions yet')).toBeTruthy()
  })

  it('shows loading, then the list', () => {
    const connection = renderList({ bots: [bot], selectedProfile: 'default', sessionListLoading: true })
    expect(screen.getByText('Loading…')).toBeTruthy()
    act(() => connection.put({ ...connection.get(), sessionListLoading: false, sessions: { default: [{ id: 's1', title: 'New' }] } }))
    expect(screen.queryByText('Loading…')).toBeNull()
  })
})
