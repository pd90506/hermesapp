import type { ReactNode } from 'react'
import type { IconName } from '../../ui/Icon.tsx'

/**
 * The Settings window's panes (K), in the Mac's order (`MacSettingsView.Pane`). Each work
 * package registers its own pane with one line in `registered.ts`; a pane not registered
 * is left out. A pane is a React component drawn into the Settings window: it shares the
 * main window's state (`useModel`, `useConnection`), but must use its elements'
 * `ownerDocument` / `defaultView`, never the global `document` / `window`, for events and
 * measurements.
 */
export type SettingsPaneID = 'servers' | 'providers' | 'capabilities' | 'sessionSources' | 'appearance' | 'notifications'

export const settingsPaneOrder: readonly SettingsPaneID[] = [
  'servers', 'providers', 'capabilities', 'sessionSources', 'appearance', 'notifications',
]

export interface SettingsPane {
  id: SettingsPaneID
  /** The tab's name, which is also the window's title while it shows. */
  title: string
  icon: IconName
  render(): ReactNode
}

const panes = new Map<SettingsPaneID, SettingsPane>()

/** Adds (or replaces) a pane. */
export function registerSettingsPane(pane: SettingsPane): void {
  panes.set(pane.id, pane)
}

/** The registered panes, in order. */
export function settingsPanes(): SettingsPane[] {
  return settingsPaneOrder.flatMap((id) => {
    const pane = panes.get(id)
    return pane ? [pane] : []
  })
}
