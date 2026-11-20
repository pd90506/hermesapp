import type { LinkState } from '@talaria/hermes-core'
import { useEffect, useState } from 'react'
import type { Shortcut } from '../../../shared/bridge.ts'
import { useConnectionSnapshot, useModel, useSnapshot } from '../../app/hooks.ts'
import { IconButton } from '../../ui/IconButton.tsx'
import { Banners } from './Banners.tsx'
import { ProfileRail } from './ProfileRail.tsx'
import './registered-tabs.ts'
import { SearchField, SessionSearchResults } from './SessionSearch.tsx'
import { TabBar } from './TabBar.tsx'
import { sidebarTabs } from './tabs.ts'
import styles from './Sidebar.module.css'

/**
 * The sidebar column, as the Mac's split view: the title band over it (the rail's
 * toggle centred over the rail's column, the profile's name with the connection under
 * it from where the list's text starts, Search and New chat at its end), then the profile rail beside the list: the picked tab's page, or the search's
 * results while the search field has text, then the banners and the tabs.
 */
export function Sidebar() {
  const model = useModel()
  const app = useSnapshot(model)
  const connection = useConnectionSnapshot()
  const bot = connection.bots.find((candidate) => candidate.name === connection.selectedProfile)
  const tabs = sidebarTabs()
  // Not kept across launches: the app opens on the sessions, as the Mac's.
  const [tabID, setTabID] = useState(tabs[0]?.id ?? '')
  const tab = tabs.find((candidate) => candidate.id === tabID) ?? tabs[0]
  const [searchShown, setSearchShown] = useState(false)
  const [searchText, setSearchText] = useState('')
  const [searchFocus, setSearchFocus] = useState(0)
  const shortcuts = window.talaria?.shortcuts

  const openSearch = () => {
    setSearchShown(true)
    setSearchFocus((token) => token + 1)
  }
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!shortcuts) return
      if (matches(event, shortcuts.search)) {
        event.preventDefault()
        openSearch()
      } else if (matches(event, shortcuts.toggleProfiles)) {
        event.preventDefault()
        model.toggleRail()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [model, shortcuts])
  // Another profile's search starts empty.
  useEffect(() => { setSearchText('') }, [connection.selectedProfile])

  const searching = searchShown && searchText.trim() !== ''
  return (
    <aside className={styles.sidebar} data-rail={app.railShown || undefined}>
      <header className={styles.band}>
        <span className={styles.trafficLights} />
        {/* Over the rail's avatars, shown or hidden, so the name beside it never moves. */}
        <span className={styles.railToggle}>
          <IconButton icon="sidebar" label={`${app.railShown ? 'Hide Profiles' : 'Show Profiles'}${shortcuts ? ` (${shortcuts.toggleProfiles.label})` : ''}`}
            onClick={() => model.toggleRail()} />
        </span>
        <div className={styles.heading}>
          <span className={styles.name}>{bot?.displayName ?? 'Talaria'}</span>
          <span className={styles.status}>{status(connection.link, connection.isTryingNoticeably, app.server?.serverURL)}</span>
        </div>
        {!searchShown && <IconButton icon="search" label={`Search Chats${shortcuts ? ` (${shortcuts.search.label})` : ''}`} onClick={openSearch} />}
        <IconButton icon="compose" label="New chat" disabled={!connection.selectedProfile || connection.link.phase !== 'connected'}
          onClick={() => {
            if (connection.selectedProfile) void model.connection.chats.newChat(connection.selectedProfile).catch(() => {})
          }} />
      </header>
      <div className={styles.columns}>
        {app.railShown && <ProfileRail />}
        <div className={styles.list}>
          {searchShown && <SearchField text={searchText} focusToken={searchFocus}
            onChange={(text) => {
              setSearchText(text)
              // Results show in the sessions' place.
              if (text && tabs[0]) setTabID(tabs[0].id)
            }}
            onClose={() => { setSearchText(''); setSearchShown(false) }} />}
          <div className={styles.page}>{searching ? <SessionSearchResults text={searchText} /> : tab && <tab.Page />}</div>
          <Banners />
          {tabs.length > 1 && <TabBar tabs={tabs} selected={tab?.id ?? ''} onSelect={setTabID} />}
        </div>
      </div>
    </aside>
  )
}

/** Whether a key press is `shortcut`, with exactly its modifiers. */
export function matches(event: KeyboardEvent, shortcut: Shortcut): boolean {
  return event.key.toLowerCase() === shortcut.key && event.ctrlKey === !!shortcut.ctrl && event.metaKey === !!shortcut.meta &&
    event.altKey === !!shortcut.alt && event.shiftKey === !!shortcut.shift
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
