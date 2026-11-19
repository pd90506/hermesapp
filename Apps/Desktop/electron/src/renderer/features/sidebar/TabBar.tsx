import { Icon } from '../../ui/Icon.tsx'
import type { SidebarTab } from './tabs.ts'
import styles from './TabBar.module.css'

/**
 * The tabs at the sidebar's bottom, as the Mac's `SessionListTabBar`: side by side on
 * a capsule floating over the list's bottom, a symbol beside each title; the picked
 * one in the accent on a grey pill. Hidden while only one tab is registered.
 */
export function TabBar({ tabs, selected, onSelect }: {
  tabs: SidebarTab[]; selected: string; onSelect: (id: string) => void
}) {
  return (
    <div className={styles.bar} role="tablist" aria-label="Sidebar">
      {tabs.map((tab) => <TabButton key={tab.id} tab={tab} selected={tab.id === selected} onSelect={onSelect} />)}
    </div>
  )
}

function TabButton({ tab, selected, onSelect }: { tab: SidebarTab; selected: boolean; onSelect: (id: string) => void }) {
  const alert = tab.useAlert?.() ?? false
  return (
    <button type="button" role="tab" aria-selected={selected} className={styles.tab} data-testid={`sessionListTab.${tab.id}`}
      onClick={() => onSelect(tab.id)}>
      <span className={styles.icon}>
        <Icon name={tab.icon} />
        {alert && <span className={styles.alert} aria-label="Needs attention" />}
      </span>
      {/* Both weights take the same room, so the bar doesn't move at a switch. */}
      <span className={styles.title} data-title={tab.title}>{tab.title}</span>
    </button>
  )
}
