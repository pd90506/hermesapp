import { useCallback, useState } from 'react'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Icon } from '../../ui/Icon.tsx'
import { settingsPanes } from './panes.ts'
import { useWindowFitting } from './SettingsWindow.tsx'
import styles from './SettingsView.module.css'

/**
 * The Settings window's content: the tabs and the pane shown. On the Mac a toolbar of
 * icon-and-label tabs over the pane, the window as tall as the pane and titled after it
 * (`MacSettingsView`); on Windows WinUI's left navigation beside it. The same elements
 * on both; platform.css and this stylesheet lay them out.
 */
export function SettingsView() {
  const model = useModel()
  const { settings } = useSnapshot(model)
  const panes = settingsPanes()
  const pane = panes.find((candidate) => candidate.id === settings.pane) ?? panes[0]
  const [element, setElement] = useState<HTMLDivElement | null>(null)
  const report = useCallback((width: number, height: number) => model.bridge.settingsWindow.setContentSize(width, height), [model])
  useWindowFitting(element, report)
  if (element && pane) element.ownerDocument.title = pane.title
  return (
    <div ref={setElement} className={styles.window}>
      <header className={styles.band}>
        <span className={styles.title}>{pane?.title ?? 'Settings'}</span>
        <span className={styles.appTitle}>Settings</span>
      </header>
      <nav className={styles.tabs} role="tablist" aria-label="Settings">
        {panes.map((candidate) => (
          <button key={candidate.id} type="button" role="tab" className={styles.tab}
            aria-selected={candidate.id === pane?.id} data-selected={candidate.id === pane?.id || undefined}
            onClick={() => model.selectSettingsPane(candidate.id)}>
            <span className={styles.tabIcon}><Icon name={candidate.icon} /></span>
            <span className={styles.tabLabel}>{candidate.title}</span>
          </button>
        ))}
      </nav>
      <section className={styles.pane} role="tabpanel" aria-label={pane?.title}>
        {pane?.render()}
      </section>
    </div>
  )
}
