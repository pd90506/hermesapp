import { alertCopy, alertKinds, isAlertOn, setAlertOn } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Form, Note, Row, Toggle } from './ui/Form.tsx'
import styles from './Pane.module.css'

/**
 * Settings ▸ Notifications, as the Mac's `NotificationsSettingsPane`: Hermes Desktop's
 * switches plus Replies in Other Chats. Notifications themselves (and the Mac's Send
 * Test Notification) come with work package J, which reads these switches.
 */
export function NotificationsPane() {
  const model = useModel()
  const { alertPreferences: prefs } = useSnapshot(model)
  return (
    <div className={styles.pane}>
      <Form>
        <Row label="Notifications">
          <Toggle label={alertCopy.enableAll} checked={prefs.isEnabled}
            onChange={(isEnabled) => model.setAlertPreferences({ ...prefs, isEnabled })} />
          <Note>{alertCopy.enableAllNote}</Note>
        </Row>
        <Row label="In the app">
          <Toggle label={alertCopy.inApp} checked={prefs.isEnabled && prefs.showsInApp} disabled={!prefs.isEnabled}
            onChange={(showsInApp) => model.setAlertPreferences({ ...prefs, showsInApp })} />
          <Note>{alertCopy.inAppNote}</Note>
        </Row>
        <Row label="Notify when">
          {alertKinds.map((kind) => (
            <div key={kind}>
              <Toggle label={alertCopy.kinds[kind].label} checked={isAlertOn(prefs, kind)} disabled={!prefs.isEnabled}
                onChange={(on) => model.setAlertPreferences(setAlertOn(prefs, kind, on))} />
              <Note>{alertCopy.kinds[kind].note}</Note>
            </div>
          ))}
        </Row>
        <Row>
          <Note>{alertCopy.hint}</Note>
        </Row>
      </Form>
    </div>
  )
}
