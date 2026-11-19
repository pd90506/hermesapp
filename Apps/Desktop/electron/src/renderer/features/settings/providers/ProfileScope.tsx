import type { ConnectionSnapshot } from '@talaria/hermes-core'
import { Row, inputClass } from './controls.tsx'
import styles from './ProvidersPane.module.css'

/**
 * Which profile a profile settings page (Providers, Capabilities) reads and writes. It
 * starts on the profile the session list shows, as Desktop's settings follow the active
 * profile (`apps/desktop/src/app/capabilities/scope-selector.tsx`; the Mac's
 * `ProfileScopePicker`). A server picker joins it once the app keeps several servers (K).
 */
export function initialProfile(snapshot: ConnectionSnapshot): string | undefined {
  return snapshot.selectedProfile ?? snapshot.bots[0]?.name
}

export function ProfilePicker({ snapshot, profile, onChange }: {
  snapshot: ConnectionSnapshot
  profile: string | undefined
  onChange: (profile: string) => void
}) {
  const bots = snapshot.bots
  return (
    <Row label="Profile">
      <select className={`${inputClass} ${styles.picker}`} aria-label="Profile" value={profile ?? ''}
        disabled={bots.length === 0} onChange={(event) => onChange(event.target.value)}>
        {bots.map((bot) => <option key={bot.name} value={bot.name}>{bot.displayName}</option>)}
        {profile !== undefined && !bots.some((bot) => bot.name === profile) && <option value={profile}>{profile}</option>}
      </select>
    </Row>
  )
}
