import { useState } from 'react'
import { alertCopy, alertKinds, isAlertOn, setAlertOn } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Button, Caption, ListRow, PageHeading, ToggleRow } from './ui/Rows.tsx'
import styles from './ui/Rows.module.css'

/**
 * Settings ▸ Notifications: Hermes Desktop's switches plus Replies in Other Chats.
 * Notifications themselves are package J's (features/notifications), which reads these
 * switches; J added Send Test Notification, as the Mac's pane has.
 */
export function NotificationsPane() {
  const model = useModel()
  const { alertPreferences: prefs } = useSnapshot(model)
  const [test, setTest] = useState<string>()
  const sendTest = () => {
    setTest(undefined)
    model.bridge.notifications.test().then((shown) => setTest(shown ? alertCopy.testSent : alertCopy.denied), () => setTest(alertCopy.denied))
  }
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
      <ListRow title="Send Test Notification" description={test ?? 'Shows a notification now, whatever the switches above say.'}
        action={<Button onClick={sendTest}>Send Test</Button>} />
    </div>
  )
}
