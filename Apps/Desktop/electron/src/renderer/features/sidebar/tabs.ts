import type { ComponentType } from 'react'
import type { IconName } from '../../ui/Icon.tsx'

/**
 * A tab of the sidebar's tab bar (the Mac's `SessionListTabBar`): Sessions, Cron Jobs.
 * Each package registers its own from its directory (`registerSidebarTab`), and adds
 * one import line to `registered-tabs.ts`; the bar draws them by `order`.
 *
 * The Mac searches from a field over the list, not a tab (`SessionListTab.barTabs`):
 * search here is the sidebar's own (`SessionSearch.tsx`), and its results take the
 * place of whichever tab shows.
 */
export interface SidebarTab {
  /** Stable: tests and the accessibility tree name the tab by it (`sessionListTab.<id>`). */
  id: string
  title: string
  icon: IconName
  /** Sessions is 0, Cron Jobs 10. */
  order: number
  /** The tab's page, in the list's place under the title band. */
  Page: ComponentType
  /**
   * A hook: whether the tab carries the red dot (Cron Jobs: a job whose last run
   * failed). Called on every render of the bar, so it must always call the same hooks.
   */
  useAlert?: () => boolean
}

const registry = new Map<string, SidebarTab>()

/** Adds (or replaces, by id) a tab. */
export function registerSidebarTab(tab: SidebarTab): void {
  registry.set(tab.id, tab)
}

/** The registered tabs, in bar order. */
export function sidebarTabs(): SidebarTab[] {
  return [...registry.values()].sort((a, b) => a.order - b.order || a.id.localeCompare(b.id))
}

/** Tests only. */
export function resetSidebarTabs(): void {
  registry.clear()
}
