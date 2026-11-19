import { isSourceHidden, knownSources, setSourceHidden, sourceLabel } from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Caption, PageHeading, ToggleRow } from './ui/Rows.tsx'

/** Settings ▸ Session Sources: which sources' sessions the list shows. */
export function SessionSourcesPane() {
  const model = useModel()
  const { sourceSettings } = useSnapshot(model)
  return (
    <div>
      <PageHeading icon="tray" title="Session Sources" />
      <Caption>Sessions this app starts are stored as Desktop, as Hermes Desktop’s are. Cron runs are under Cron Jobs. Hiding a source only filters the list; nothing is deleted.</Caption>
      {knownSources().map((source) => (
        <ToggleRow key={source} label={sourceLabel(source)} description={`Source “${source}”`}
          checked={!isSourceHidden(sourceSettings, source)}
          onChange={(shown) => model.setSourceSettings(setSourceHidden(sourceSettings, source, !shown))} />
      ))}
    </div>
  )
}
