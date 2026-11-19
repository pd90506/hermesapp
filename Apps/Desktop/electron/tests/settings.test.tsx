import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { Observable, defaultAlertPreferences, isAlertOn, type AlertPreferences, type SessionSourceSettings } from '@talaria/hermes-core'
import { createElement } from 'react'
import { ModelContext } from '../src/renderer/app/hooks.ts'
import type { AppModel, AppSnapshot } from '../src/renderer/app/model.ts'
import { registerSettingsPane, settingsPanes } from '../src/renderer/features/settings/panes.ts'
import '../src/renderer/features/settings/registered.ts'
import { NotificationsPane } from '../src/renderer/features/settings/NotificationsPane.tsx'
import { SessionSourcesPane } from '../src/renderer/features/settings/SessionSourcesPane.tsx'

class FakeModel extends Observable<Partial<AppSnapshot>> {
  constructor() {
    super({ sourceSettings: { hiddenSources: [] }, alertPreferences: defaultAlertPreferences })
  }
  setSourceSettings(sourceSettings: SessionSourceSettings) { this.set({ ...this.get(), sourceSettings }) }
  setAlertPreferences(alertPreferences: AlertPreferences) { this.set({ ...this.get(), alertPreferences }) }
}

function renderPane(pane: () => ReturnType<typeof createElement>) {
  const model = new FakeModel()
  render(<ModelContext.Provider value={model as unknown as AppModel}>{pane()}</ModelContext.Provider>)
  return model
}

afterEach(cleanup)

describe('settings panes', () => {
  it('come in the Mac’s order, whatever order they register in', () => {
    registerSettingsPane({ id: 'appearance', title: 'Appearance', icon: 'palette', render: () => null })
    registerSettingsPane({ id: 'providers', title: 'Providers', icon: 'key', render: () => null })
    expect(settingsPanes().map((pane) => pane.id)).toEqual(['servers', 'providers', 'sessionSources', 'appearance', 'notifications'])
  })

  it('Session Sources hides a source', () => {
    const model = renderPane(() => <SessionSourcesPane />)
    fireEvent.click(screen.getByLabelText(/Terminal \(TUI\)/))
    expect(model.get().sourceSettings?.hiddenSources).toEqual(['tui'])
  })

  it('Notifications: switching all off disables each kind', () => {
    const model = renderPane(() => <NotificationsPane />)
    fireEvent.click(screen.getByLabelText('Response Ready'))
    expect(isAlertOn(model.get().alertPreferences!, 'turnDone')).toBe(false)
    fireEvent.click(screen.getByLabelText('Enable Notifications'))
    expect((screen.getByLabelText('Approval Needed') as HTMLInputElement).disabled).toBe(true)
  })
})
