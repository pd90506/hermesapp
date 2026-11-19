import { isSourceHidden, knownSources, setSourceHidden, sourceLabel } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Form, Note, Row, Toggle } from './ui/Form.tsx'
import styles from './Pane.module.css'

/** Settings ▸ Session Sources, as the Mac's `SessionSourcesSettingsPane`. */
export function SessionSourcesPane() {
  const model = useModel()
  const { sourceSettings } = useSnapshot(model)
  return (
    <div className={styles.pane}>
      <Form>
        <Row label="Show in session list">
          {knownSources().map((source) => (
            <Toggle key={source} label={sourceLabel(source)} detail={source}
              checked={!isSourceHidden(sourceSettings, source)}
              onChange={(shown) => model.setSourceSettings(setSourceHidden(sourceSettings, source, !shown))} />
          ))}
          <Note>Sessions this app starts are stored as Desktop, as Hermes Desktop’s are. The list shows only Desktop and Terminal (TUI) sessions, as Hermes Desktop’s does; cron runs are under Cron Jobs. Hiding a source only filters the list; nothing is deleted.</Note>
        </Row>
      </Form>
    </div>
  )
}
