import { useEffect, useRef } from 'react'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Icon } from '../../ui/Icon.tsx'
import { settingsPanes } from './panes.ts'
import './registered.ts'
import styles from './SettingsOverlay.module.css'

/**
 * Settings, drawn over the main window as Hermes Desktop's settings overlay
 * (`apps/desktop/src/app/settings`, MIT): a dimmed backdrop under the title band, a card
 * with the panes listed on the left and the one picked beside them, a close button.
 * Esc or a click on the backdrop closes it. The same on macOS and Windows.
 */
export function SettingsOverlay() {
  const model = useModel()
  const { settings } = useSnapshot(model)
  const card = useRef<HTMLDivElement>(null)
  const open = settings.open

  useEffect(() => {
    if (!open) return
    const previous = document.activeElement as HTMLElement | null
    card.current?.focus()
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !event.defaultPrevented) {
        event.preventDefault()
        model.closeSettings()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      previous?.focus?.()
    }
  }, [open, model])

  if (!open) return null
  const panes = settingsPanes()
  const pane = panes.find((candidate) => candidate.id === settings.pane) ?? panes[0]
  return (
    <div className={styles.backdrop} onMouseDown={(event) => {
      if (event.target === event.currentTarget) model.closeSettings()
    }}>
      <div ref={card} className={styles.card} role="dialog" aria-modal="true" aria-label="Settings" tabIndex={-1}>
        <nav className={styles.nav} aria-label="Settings">
          <div className={styles.navTitle}>Settings</div>
          {panes.map((candidate) => (
            <button key={candidate.id} type="button" className={styles.navItem}
              aria-current={candidate.id === pane?.id ? 'page' : undefined}
              onClick={() => model.selectSettingsPane(candidate.id)}>
              <span className={styles.navIcon}><Icon name={candidate.icon} /></span>
              <span className={styles.navLabel}>{candidate.title}</span>
            </button>
          ))}
        </nav>
        <main className={styles.main} aria-label={pane?.title}>
          <div className={styles.content}>{pane?.render()}</div>
        </main>
        <button type="button" className={styles.close} title="Close Settings (Esc)" aria-label="Close Settings"
          onClick={() => model.closeSettings()}><Icon name="close" /></button>
      </div>
    </div>
  )
}
