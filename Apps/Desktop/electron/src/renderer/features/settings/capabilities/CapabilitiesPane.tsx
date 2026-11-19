import { useEffect, useMemo, useState, type ReactNode } from 'react'
import {
  CapabilitiesBoard, capabilityID, capabilityKinds, capabilityNote, capabilityTitles, describeError, filterCapabilities,
  type Capability, type CapabilityKind,
} from '@talaria/hermes-core'
import { useConnection, useSnapshot } from '../../../app/hooks.ts'
import { PageHeading } from '../ui/Rows.tsx'
import { Button, Segmented, Spinner, Switch, errorClass, inputClass } from '../providers/controls.tsx'
import { ProfilePicker, initialProfile } from '../providers/ProfileScope.tsx'
import type { SettingsConnection } from '../providers/ProvidersPane.tsx'
import styles from './CapabilitiesPane.module.css'

const kinds = capabilityKinds.map((kind) => ({ value: kind, title: capabilityTitles[kind] }))

/** The Capabilities settings pane for the app's connection (registered in K's pane table). */
export function CapabilitiesSettingsPane() {
  return <CapabilitiesPane connection={useConnection()} />
}

/**
 * The installed skills, toolsets, MCP servers and plugins of a profile, each with its
 * switch: the Mac's `CapabilitiesView`, Desktop's Capabilities page without its catalogs
 * and marketplace. A tab per kind, a search field, and rows a switch each.
 */
export function CapabilitiesPane({ connection, board: given }: { connection: SettingsConnection; board?: CapabilitiesBoard }) {
  const snapshot = useSnapshot(connection)
  const board = useMemo(() => given ?? new CapabilitiesBoard(connection), [given, connection])
  const state = useSnapshot(board)
  const [profile, setProfile] = useState(() => initialProfile(snapshot))
  const [kind, setKind] = useState<CapabilityKind>('skills')
  const [query, setQuery] = useState('')
  const [actionError, setActionError] = useState<string>()
  const connected = snapshot.link.phase === 'connected'

  useEffect(() => {
    if (profile === undefined) setProfile(initialProfile(snapshot))
  }, [profile, snapshot])
  const refresh = () => {
    if (connected && profile !== undefined) void board.refresh(kind, profile)
  }
  useEffect(refresh, [board, connected, profile, kind])

  const current = state.profile === profile ? state : undefined
  const list = current?.lists[kind]
  const shown = filterCapabilities(list ?? [], query)
  const flip = (row: Capability, on: boolean) => {
    board.setEnabled(row, on).then(() => setActionError(undefined), (error: unknown) => setActionError(describeError(error)))
  }

  let placeholder: ReactNode
  if (!connected) {
    placeholder = <Empty title="Not Connected" detail="Connect to the server to see its capabilities." />
  } else if (current?.isAvailable === false) {
    placeholder = <Empty title="Not Available" detail="This connection can't read the profile's settings." />
  } else if (current?.errors[kind] && !list) {
    placeholder = <Empty title={`Couldn't Load ${capabilityTitles[kind]}`} detail={current.errors[kind]}
      action={<Button onClick={refresh}>Try Again</Button>} />
  } else if (!list) {
    placeholder = <Spinner label="Loading" />
  } else if (shown.length === 0) {
    placeholder = query.trim() === ''
      ? <Empty title={`No ${capabilityTitles[kind]}`} detail="None are installed in this profile." />
      : <Empty title={`No Results for “${query.trim()}”`} detail="Check the spelling or try a new search." />
  }

  return (
    <div className={styles.pane}>
      <PageHeading icon="puzzle" title="Capabilities" />
      <div className={styles.toolbar}>
        <div className={styles.scope}><ProfilePicker snapshot={snapshot} profile={profile} onChange={setProfile} /></div>
        <input className={`${inputClass} ${styles.search}`} type="search" aria-label="Search"
          placeholder={`Search ${capabilityTitles[kind].toLowerCase()}`} spellCheck={false}
          value={query} onChange={(event) => setQuery(event.target.value)} />
      </div>
      <Segmented label="Kind" value={kind} options={kinds} onChange={setKind} />
      <div className={styles.list} role="list" aria-label={capabilityTitles[kind]}>
        {placeholder ? <div className={styles.placeholder}>{placeholder}</div> : shown.map((row) => (
          <CapabilityRow key={capabilityID(row)} row={row} saving={current?.saving.has(capabilityID(row)) === true}
            onChange={(on) => flip(row, on)} />
        ))}
      </div>
      <div className={styles.footnote}>
        {actionError && <p className={errorClass} role="alert">{actionError}</p>}
        <span>{kind === 'plugins'
          ? 'Plugins are installed with Hermes. Switching one loads or unloads it for this profile.'
          : 'Changes apply to chats started after them.'}</span>
      </div>
    </div>
  )
}

/** A capability: its name and what it does, its tags under them, its switch at the end. */
function CapabilityRow({ row, saving, onChange }: { row: Capability; saving: boolean; onChange: (on: boolean) => void }) {
  const note = capabilityNote(row)
  return (
    <div className={styles.row} role="listitem" data-testid={`capability.${row.kind}.${row.name}`}>
      <div className={styles.text}>
        <div className={styles.title}>
          <span className={styles.titleText}>{row.title}</span>
          {saving && <Spinner />}
        </div>
        {row.detail && <div className={styles.detail}>{row.detail}</div>}
        {note && <div className={row.needsSetup ? styles.noteCaution : styles.note}>{note}</div>}
      </div>
      <Switch label={row.title} checked={row.isEnabled} disabled={row.lockedReason !== undefined || saving} onChange={onChange} />
    </div>
  )
}

function Empty({ title, detail, action }: { title: string; detail?: string | undefined; action?: ReactNode }) {
  return (
    <div className={styles.empty}>
      <div className={styles.emptyTitle}>{title}</div>
      {detail && <div className={styles.emptyDetail}>{detail}</div>}
      {action}
    </div>
  )
}
