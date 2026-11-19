import { alertCopy, alertKinds, isAlertOn, setAlertOn } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Caption, PageHeading, ToggleRow } from './ui/Rows.tsx'
import styles from './ui/Rows.module.css'

/**
 * Settings ▸ Notifications: Hermes Desktop's switches plus Replies in Other Chats.
 * Notifications themselves come with work package J, which reads these switches.
 */
export function NotificationsPane() {
  const model = useModel()
  const { alertPreferences: prefs } = useSnapshot(model)
  return (
    <div>
      <PageHeading icon="bell" title="Notifications" />
      <ToggleRow label={alertCopy.enableAll} description={alertCopy.enableAllNote} checked={prefs.isEnabled}
        onChange={(isEnabled) => model.setAlertPreferences({ ...prefs, isEnabled })} />
      <ToggleRow label={alertCopy.inApp} description={alertCopy.inAppNote}
        checked={prefs.isEnabled && prefs.showsInApp} disabled={!prefs.isEnabled}
        onChange={(showsInApp) => model.setAlertPreferences({ ...prefs, showsInApp })} />
      <h3 className={styles.sectionTitle}>Notify when</h3>
      {alertKinds.map((kind) => (
        <ToggleRow key={kind} label={alertCopy.kinds[kind].label} description={alertCopy.kinds[kind].note}
          checked={isAlertOn(prefs, kind)} disabled={!prefs.isEnabled}
          onChange={(on) => model.setAlertPreferences(setAlertOn(prefs, kind, on))} />
      ))}
      <Caption>{alertCopy.hint}</Caption>
    </div>
  )
}
