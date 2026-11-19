import type { ReactNode } from 'react'
import type { IconName } from '../../ui/Icon.tsx'

/**
 * The Settings panes (K), listed down the Settings overlay's left side in this order.
 * Each work package registers its own pane with one line in `registered.ts`; a pane not
 * registered is left out. A pane is a React component drawn in the main window: it
 * shares the app's state (`useModel`, `useConnection`). Build it from `ui/Rows.tsx`
 * (PageHeading, ListRow, ToggleRow…) so every pane looks the same on every platform.
 */
export type SettingsPaneID = 'servers' | 'providers' | 'capabilities' | 'sessionSources' | 'appearance' | 'notifications'

export const settingsPaneOrder: readonly SettingsPaneID[] = [
  'servers', 'providers', 'capabilities', 'sessionSources', 'appearance', 'notifications',
]

export interface SettingsPane {
  id: SettingsPaneID
  /** The pane's name in the overlay's left list. */
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
