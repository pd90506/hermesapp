import { useEffect, useMemo, useRef, useState } from 'react'
import {
  ProvidersBoard, accountIsConnected, accountSignsInHere, accountStatus, describeError, emptyEndpointDraft,
  endpointDraftCanSave, filterKeyGroups, isKeyVar,
  type ConnectionSnapshot, type CustomEndpoint, type GatewayAccess, type Observable, type ProviderAccount,
  type ProviderEnvVar, type ProviderSignIn, type ProvidersSnapshot,
} from '@talaria/hermes-core'
import { useModel, useSnapshot } from '../../../app/hooks.ts'
import { Button, Confirm, Dialog, Field, MoreMenu, Row, Section, Segmented, Spinner, errorClass, inputClass, messageClass } from './controls.tsx'
import { ProfilePicker, initialProfile } from './ProfileScope.tsx'
import styles from './ProvidersPane.module.css'

type Page = 'accounts' | 'keys' | 'endpoints'

const pages: ReadonlyArray<{ value: Page; title: string }> = [
  { value: 'accounts', title: 'Accounts' },
  { value: 'keys', title: 'API Keys' },
  { value: 'endpoints', title: 'Endpoints' },
]

/** What the pane reads: the connection's snapshot (link, bots) and its REST routes and socket. */
export type SettingsConnection = Observable<ConnectionSnapshot> & GatewayAccess

/** The Providers settings pane for the app's connection (registered in K's pane table). */
export function ProvidersSettingsPane() {
  return <ProvidersPane connection={useModel().connection} />
}

/**
 * Where a profile's models come from: accounts signed in with a device code, API keys,
 * and OpenAI-compatible endpoints. The Mac's `ProvidersView`, after Desktop's Settings →
 * Providers (`apps/desktop/src/app/settings/providers-settings.tsx`, `custom-endpoints-settings.tsx`).
 */
export function ProvidersPane({ connection, board: given }: { connection: SettingsConnection; board?: ProvidersBoard }) {
  const snapshot = useSnapshot(connection)
  const board = useMemo(() => given ?? new ProvidersBoard(connection), [given, connection])
  const state = useSnapshot(board)
  const [profile, setProfile] = useState(() => initialProfile(snapshot))
  const [page, setPage] = useState<Page>('accounts')
  const [keyQuery, setKeyQuery] = useState('')
  const [openGroups, setOpenGroups] = useState<ReadonlySet<string>>(new Set())
  const [editingKey, setEditingKey] = useState<ProviderEnvVar>()
  const [keyValue, setKeyValue] = useState('')
  const [removingKey, setRemovingKey] = useState<ProviderEnvVar>()
  const [disconnecting, setDisconnecting] = useState<ProviderAccount>()
  const [deletingEndpoint, setDeletingEndpoint] = useState<CustomEndpoint>()
  const [addingEndpoint, setAddingEndpoint] = useState(false)
  /** The last change the server refused. */
  const [actionError, setActionError] = useState<string>()

  const connected = snapshot.link.phase === 'connected'
  useEffect(() => {
    if (profile === undefined) setProfile(initialProfile(snapshot))
  }, [profile, snapshot])
  useEffect(() => {
    if (connected && profile !== undefined) void board.refresh(profile)
  }, [board, connected, profile])
  useEffect(() => () => board.cancelSignIn(), [board])

  const perform = (action: () => Promise<void>) => {
    action().then(() => setActionError(undefined), (error: unknown) => setActionError(describeError(error)))
  }
  const shown = state.profile === profile ? state : undefined
  const error = actionError ?? shown?.error

  return (
    <div className={styles.pane}>
      <Section footer={error && <p className={errorClass} role="alert">{error}</p>}>
        <ProfilePicker snapshot={snapshot} profile={profile} onChange={setProfile} />
        {shown?.currentModel && (
          <Row label="Default model">
            <span className={styles.value}>{shown.currentProvider ? `${shown.currentModel} · ${shown.currentProvider}` : shown.currentModel}</span>
          </Row>
        )}
      </Section>
      {shown?.hasLoaded ? (
        <>
          <Segmented label="Show" value={page} options={pages} onChange={setPage} />
          {page === 'accounts' && <Accounts state={shown} onSignIn={(a) => perform(() => board.startSignIn(a))} onDisconnect={setDisconnecting} />}
          {page === 'keys' && (
            <Keys state={shown} query={keyQuery} onQuery={setKeyQuery} openGroups={openGroups}
              onToggle={(name, open) => {
                const next = new Set(openGroups)
                if (open) next.add(name)
                else next.delete(name)
                setOpenGroups(next)
              }}
              onEdit={(variable) => { setKeyValue(''); setEditingKey(variable) }} onRemove={setRemovingKey} />
          )}
          {page === 'endpoints' && (
            <Endpoints state={shown} onAdd={() => setAddingEndpoint(true)} onDelete={setDeletingEndpoint}
              onActivate={(endpoint) => perform(() => board.activateEndpoint(endpoint))} />
          )}
        </>
      ) : !connected ? (
        <Section><Row label={<span className={styles.placeholder}>Connect to the server to set up its providers.</span>} /></Section>
      ) : state.isAvailable === false ? (
        <Section><Row label={<span className={styles.placeholder}>This connection can't read the profile's settings.</span>} /></Section>
      ) : (
        <div className={styles.loading}><Spinner label="Loading" /></div>
      )}

      <Dialog open={editingKey !== undefined} title={editingKey ? `Set ${editingKey.key}` : ''} onClose={() => setEditingKey(undefined)}
        actions={<>
          <Button onClick={() => setEditingKey(undefined)}>Cancel</Button>
          <Button kind="primary" disabled={keyValue.trim() === ''} onClick={() => {
            const variable = editingKey
            setEditingKey(undefined)
            if (variable) perform(() => board.setKey(variable.key, keyValue))
            setKeyValue('')
          }}>Save</Button>
        </>}>
        {editingKey?.description && <p className={messageClass}>{editingKey.description}</p>}
        <input className={inputClass} aria-label="Value" autoFocus spellCheck={false} value={keyValue}
          type={editingKey && isKeyVar(editingKey) ? 'password' : 'text'} onChange={(event) => setKeyValue(event.target.value)} />
      </Dialog>
      <Confirm open={removingKey !== undefined} title={removingKey ? `Remove ${removingKey.key}?` : ''} action="Remove"
        message="The key is deleted from the profile's .env, with any copy of it in config.yaml."
        onConfirm={() => { const key = removingKey; if (key) perform(() => board.removeKey(key.key)) }}
        onClose={() => setRemovingKey(undefined)} />
      <Confirm open={disconnecting !== undefined} title={disconnecting ? `Disconnect ${disconnecting.name}?` : ''} action="Disconnect"
        message="Hermes forgets this account's sign-in. Models from it stop working until you sign in again."
        onConfirm={() => { const account = disconnecting; if (account) perform(() => board.disconnect(account)) }}
        onClose={() => setDisconnecting(undefined)} />
      <Confirm open={deletingEndpoint !== undefined} title={deletingEndpoint ? `Delete “${deletingEndpoint.name}”?` : ''} action="Delete"
        onConfirm={() => { const endpoint = deletingEndpoint; if (endpoint) perform(() => board.deleteEndpoint(endpoint)) }}
        onClose={() => setDeletingEndpoint(undefined)} />
      <SignInDialog signIn={shown?.signIn} onClose={() => board.cancelSignIn()} />
      <EndpointEditor open={addingEndpoint} board={board} onClose={() => setAddingEndpoint(false)} />
    </div>
  )
}

function Accounts({ state, onSignIn, onDisconnect }: {
  state: ProvidersSnapshot
  onSignIn: (account: ProviderAccount) => void
  onDisconnect: (account: ProviderAccount) => void
}) {
  return (
    <Section header="Accounts" footer="Sign in with a subscription. The code is entered in any browser; Hermes keeps the sign-in.">
      {state.accounts.map((account) => (
        <Row key={account.id} testID={`providerAccount.${account.id}`} label={account.name}
          detail={<span className={accountIsConnected(account) ? styles.connected : undefined}>{accountStatus(account)}</span>}>
          {state.saving.has(account.id) ? <Spinner /> : accountIsConnected(account)
            ? account.canDisconnect && <Button onClick={() => onDisconnect(account)}>Disconnect</Button>
            : accountSignsInHere(account) && <Button testID={`providerSignIn.${account.id}`} onClick={() => onSignIn(account)}>Sign In</Button>}
        </Row>
      ))}
    </Section>
  )
}

function Keys({ state, query, onQuery, openGroups, onToggle, onEdit, onRemove }: {
  state: ProvidersSnapshot
  query: string
  onQuery: (query: string) => void
  openGroups: ReadonlySet<string>
  onToggle: (name: string, open: boolean) => void
  onEdit: (variable: ProviderEnvVar) => void
  onRemove: (variable: ProviderEnvVar) => void
}) {
  const groups = filterKeyGroups(state.keyGroups, query)
  return (
    <Section header="API Keys" footer="Keys are saved in the profile's .env on the server and never shown again.">
      <div className={styles.searchRow}>
        <input className={inputClass} type="search" placeholder="Search providers" aria-label="Search providers"
          value={query} spellCheck={false} onChange={(event) => onQuery(event.target.value)} />
      </div>
      {groups.map((group) => (
        <details key={group.name} className={styles.group} open={openGroups.has(group.name) || query.trim() !== ''}
          data-testid={`providerKeys.${group.name}`}
          onToggle={(event) => {
            const open = (event.currentTarget as HTMLDetailsElement).open
            if (query.trim() === '' && open !== openGroups.has(group.name)) onToggle(group.name, open)
          }}>
          <summary className={styles.groupSummary}>
            <span className={styles.groupName}>{group.name}</span>
            {group.hasAnySet && <span className={styles.check} role="img" aria-label="Key set">✓</span>}
          </summary>
          <div className={styles.groupBody}>
            {group.description && <p className={styles.groupDescription}>{group.description}</p>}
            {[group.primary, ...group.others].map((variable) => (
              <Row key={variable.key} label={<span className={styles.mono}>{variable.key}</span>}
                detail={variable.isSet ? variable.redactedValue ?? 'Set' : 'Not set'}>
                {state.saving.has(variable.key) ? <Spinner /> : (
                  <>
                    {variable.isSet && <Button kind="destructive" onClick={() => onRemove(variable)}>Remove</Button>}
                    <Button testID={`providerKey.set.${variable.key}`} onClick={() => onEdit(variable)}>
                      {variable.isSet ? 'Change…' : 'Set…'}
                    </Button>
                  </>
                )}
              </Row>
            ))}
            {group.docsURL && <a className={styles.link} href={group.docsURL} target="_blank" rel="noreferrer">Get a key</a>}
          </div>
        </details>
      ))}
    </Section>
  )
}

function Endpoints({ state, onAdd, onActivate, onDelete }: {
  state: ProvidersSnapshot
  onAdd: () => void
  onActivate: (endpoint: CustomEndpoint) => void
  onDelete: (endpoint: CustomEndpoint) => void
}) {
  return (
    <Section header="Custom Endpoints" footer="Any OpenAI-compatible server, such as a local model or a gateway.">
      {state.endpoints.map((endpoint) => (
        <Row key={endpoint.id} testID={`customEndpoint.${endpoint.id}`}
          label={<>{endpoint.name}{endpoint.isCurrent && <span className={styles.badge}>Default</span>}</>}
          detail={<span className={styles.oneLine}>{[endpoint.baseURL, endpoint.model].filter((s) => s !== '').join(' · ')}</span>}>
          {state.saving.has(endpoint.id) ? <Spinner /> : (
            <MoreMenu items={[
              { title: 'Make Default', disabled: endpoint.isCurrent, onSelect: () => onActivate(endpoint) },
              { title: 'Delete…', destructive: true, onSelect: () => onDelete(endpoint) },
            ]} />
          )}
        </Row>
      ))}
      <button type="button" className={styles.addRow} data-testid="customEndpoint.add" onClick={onAdd}>
        <span aria-hidden="true">+</span> Add Endpoint…
      </button>
    </Section>
  )
}

/** The device code to enter at the provider's page, while Hermes waits for the sign-in. */
function SignInDialog({ signIn, onClose }: { signIn: ProviderSignIn | undefined; onClose: () => void }) {
  const codeRef = useRef<HTMLDivElement>(null)
  const status = signIn?.status
  const copy = () => {
    const view = codeRef.current?.ownerDocument.defaultView
    if (signIn) void view?.navigator.clipboard?.writeText(signIn.userCode).catch(() => {})
  }
  return (
    <Dialog open={signIn !== undefined} title={signIn ? `Sign in to ${signIn.providerName}` : ''} onClose={onClose}
      actions={status?.phase === 'waiting'
        ? <Button onClick={onClose}>Cancel</Button>
        : <Button kind="primary" onClick={onClose}>Done</Button>}>
      {status?.phase === 'waiting' && signIn && (
        <div className={styles.signIn}>
          <p className={messageClass}>Open the sign-in page and enter this code:</p>
          <div ref={codeRef} className={styles.code} data-testid="providerSignIn.code">{signIn.userCode}</div>
          <div className={styles.signInActions}>
            {signIn.verificationURL && (
              <a className={styles.primaryLink} href={signIn.verificationURL} target="_blank" rel="noreferrer">Open Sign-In Page</a>
            )}
            <Button onClick={copy}>Copy Code</Button>
          </div>
          <div className={styles.waiting}><Spinner label="Waiting" /> Waiting for you to approve…</div>
        </div>
      )}
      {status?.phase === 'approved' && <p className={styles.approved}>✓ Signed in</p>}
      {status?.phase === 'failed' && <p className={errorClass} role="alert">{status.reason}</p>}
    </Dialog>
  )
}

/** Add Endpoint: a name, its OpenAI-compatible base URL, a model, and its key if it needs one. */
function EndpointEditor({ open, board, onClose }: { open: boolean; board: ProvidersBoard; onClose: () => void }) {
  const [draft, setDraft] = useState(emptyEndpointDraft)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string>()
  useEffect(() => {
    if (open) { setDraft(emptyEndpointDraft()); setError(undefined) }
  }, [open])
  const save = () => {
    setSaving(true)
    setError(undefined)
    board.addEndpoint(draft).then(onClose, (e: unknown) => setError(describeError(e))).finally(() => setSaving(false))
  }
  const text = (key: 'name' | 'baseURL' | 'model' | 'apiKey', label: string, placeholder: string, type = 'text') => (
    <Field label={label}>
      <input className={inputClass} type={type} placeholder={placeholder} spellCheck={false} value={draft[key]}
        data-testid={key === 'baseURL' ? 'endpointEditor.baseURL' : undefined}
        onChange={(event) => setDraft({ ...draft, [key]: event.target.value })} />
    </Field>
  )
  return (
    <Dialog open={open} wide title="Add Endpoint" onClose={() => { if (!saving) onClose() }}
      actions={<>
        <Button disabled={saving} onClick={onClose}>Cancel</Button>
        {saving ? <Spinner /> : <Button kind="primary" disabled={!endpointDraftCanSave(draft)} onClick={save}>Add</Button>}
      </>}>
      {text('name', 'Name', 'Local server')}
      {text('baseURL', 'Base URL', 'http://127.0.0.1:8000/v1')}
      {text('model', 'Model', 'qwen3-coder')}
      {text('apiKey', 'API Key', 'Optional', 'password')}
      <label className={styles.checkbox}>
        <input type="checkbox" checked={draft.makeDefault} onChange={(event) => setDraft({ ...draft, makeDefault: event.target.checked })} />
        Make it the default
      </label>
      {error && <p className={errorClass} role="alert">{error}</p>}
    </Dialog>
  )
}
