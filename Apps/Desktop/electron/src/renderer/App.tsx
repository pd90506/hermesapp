import { useEffect } from 'react'
import { ModelContext, useSnapshot } from './app/hooks.ts'
import type { AppModel } from './app/model.ts'
import { ChatPane } from './features/chat/ChatPane.tsx'
import { ConnectPage } from './features/connect/ConnectPage.tsx'
import { SettingsOverlay } from './features/settings/SettingsOverlay.tsx'
import { Sidebar } from './features/sidebar/Sidebar.tsx'
import styles from './App.module.css'

/** The window: the connect page, or the sidebar beside the chat (the Mac's split view). */
export function App({ model }: { model: AppModel }) {
  const app = useSnapshot(model)
  const accent = app.appearance.accent
  useEffect(() => {
    // The system accent, as the native controls draw it; the tokens' fallback otherwise.
    const root = document.documentElement
    if (accent) root.style.setProperty('--accent', accent)
    else root.style.removeProperty('--accent')
  }, [accent])
  if (!app.loaded) return null
  return (
    <ModelContext.Provider value={model}>
      {app.showsConnectPage ? <ConnectPage /> : (
        <div className={styles.window}>
          <Sidebar />
          <ChatPane />
        </div>
      )}
      <SettingsOverlay />
    </ModelContext.Provider>
  )
}
