import type { LinkState } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { IconButton } from '../../ui/IconButton.tsx'
import { ProfileRail } from './ProfileRail.tsx'
import { useState } from 'react'
import './registered-tabs.ts'
import { TabBar } from './TabBar.tsx'
import { sidebarTabs } from './tabs.ts'
import styles from './Sidebar.module.css'

/**
 * The sidebar column, as the Mac's split view: the title band over it (the rail's
 * toggle, the profile's name with the connection under it, New chat at its end), then
 * the profile rail beside the session list.
 */
export function Sidebar() {
  const model = useModel()
  const app = useSnapshot(model)
  const connection = useSnapshot(model.connection)
  const bot = connection.bots.find((candidate) => candidate.name === connection.selectedProfile)
  const tabs = sidebarTabs()
  // Not kept across launches: the app opens on the sessions, as the Mac's.
  const [tabID, setTabID] = useState(tabs[0]?.id ?? '')
  const tab = tabs.find((candidate) => candidate.id === tabID) ?? tabs[0]
  return (
    <aside className={styles.sidebar} data-rail={app.railShown || undefined}>
      <header className={styles.band}>
        <span className={styles.trafficLights} />
        <IconButton icon="sidebar" label={app.railShown ? 'Hide Profiles' : 'Show Profiles'} onClick={() => model.toggleRail()} />
        <div className={styles.heading}>
          <span className={styles.name}>{bot?.displayName ?? 'Talaria'}</span>
          <span className={styles.status}>{status(connection.link, connection.isTryingNoticeably, app.server?.serverURL)}</span>
        </div>
        <IconButton icon="compose" label="New chat" disabled />
      </header>
      <div className={styles.columns}>
        {app.railShown && <ProfileRail />}
        <div className={styles.list}>
          <div className={styles.page}>{tab && <tab.Page />}</div>
          {tabs.length > 1 && <TabBar tabs={tabs} selected={tab?.id ?? ''} onSelect={setTabID} />}
        </div>
      </div>
    </aside>
  )
}

/** The connection, under the profile's name; a short reconnect shows nothing (the user, 2026-10-19). */
export function status(link: LinkState, noticeably: boolean, serverURL: string | undefined): string {
  const host = (serverURL ?? '').replace(/^\w+:\/\//, '').replace(/\/+$/, '')
  switch (link.phase) {
    case 'connected': return host
    case 'connecting':
    case 'reconnecting': return noticeably ? (link.phase === 'connecting' ? 'Connecting…' : 'Reconnecting…') : host
    case 'failed': return 'Couldn’t connect'
    case 'disconnected': return 'Not connected'
  }
}
