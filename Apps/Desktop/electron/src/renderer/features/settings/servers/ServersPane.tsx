import {
  authModeCopy, authModes, defaultServerName, localServerName, type AuthMode, type ServerEntry,
} from '@talaria/hermes-core'
import { useEffect, useId, useRef, useState, type ReactNode } from 'react'
import { useModel, useServers, useSnapshot } from '../../../app/hooks.ts'
import { Icon } from '../../../ui/Icon.tsx'
import { Button, Caption, ListRow, PageHeading, Pill, Select, Spinner, TextField, ToggleRow } from '../ui/Rows.tsx'
import { linkStatus } from './status.ts'
import styles from './ServersPane.module.css'

/**
 * Settings ▸ Servers: one card per server (name, address, status, Connect / Disconnect),
 * which opens to edit it; Add Server in the heading; the switch that runs Hermes on this
 * computer. Laid out as Hermes Desktop's settings pages, the same on every platform.
 */
export function ServersPane() {
  const model = useModel()
  const { servers, runsLocalBackend } = useServers()
  const [expandedID, setExpandedID] = useState<string | undefined>()
  const [localAvailable, setLocalAvailable] = useState<boolean | undefined>()

  useEffect(() => {
    // Nothing to edit yet: start with a blank server, open.
    if (servers.length === 0) setExpandedID(model.servers.add())
    void model.bridge.localBackend.available().then(setLocalAvailable, () => setLocalAvailable(false))
    // Only when the pane opens.
  }, [])

  return (
    <div>
      <PageHeading icon="server" title="Servers" aside={
        <Button onClick={() => setExpandedID(model.servers.add())}><Icon name="add" />Add Server</Button>
      } />
      <Caption>The Hermes dashboards this app connects to. Each server’s profiles show in the rail.</Caption>
      <div className={styles.list}>
        {servers.map((server) => (
          <ServerCard key={server.id} server={server} expanded={server.id === expandedID}
            onToggle={() => setExpandedID(server.id === expandedID ? undefined : server.id)} />
        ))}
      </div>
      {(localAvailable || runsLocalBackend) && (
        <div className={styles.section}>
          <ToggleRow label={`Run Hermes on ${localServerName(model.bridge.platform).replace('This', 'this')}`}
            description="Starts hermes serve on this computer, as Hermes Desktop does: on a free port, with a new token each time. It stops when you quit the app."
            checked={runsLocalBackend}
            onChange={(on) => void model.servers.setRunsLocalBackend(on)} />
        </div>
      )}
    </div>
  )
}

function ServerCard({ server, expanded, onToggle }: { server: ServerEntry; expanded: boolean; onToggle: () => void }) {
  const model = useModel()
  const connection = useSnapshot(server.connection)
  const status = linkStatus(connection.link)
  const isConnected = connection.link.phase === 'connected'
  const detailID = useId()
  return (
    <section className={styles.card} aria-label={server.name}>
      <div className={styles.header}>
        <button type="button" className={styles.summary} aria-expanded={expanded} aria-controls={detailID} onClick={onToggle}>
          <span className={styles.kindIcon}><Icon name={server.isLocal ? 'computer' : 'globe'} /></span>
          <span className={styles.names}>
            <span className={styles.name}>{server.name}</span>
            <span className={styles.address}>{server.config.serverURL || (server.isLocal ? 'Not running' : 'No address yet')}</span>
          </span>
          <span className={styles.chevron} data-open={expanded || undefined}><Icon name="chevronDown" /></span>
        </button>
        <Pill tone={status.tone}>{connection.link.phase === 'failed' ? 'Failed' : status.text}</Pill>
        {isConnected
          ? <Button onClick={() => void model.servers.disconnect(server.id)}>{server.isLocal ? 'Stop' : 'Disconnect'}</Button>
          : <Button variant="primary" disabled={server.connecting || (!server.isLocal && !server.hasURL)}
              onClick={() => void model.servers.connect(server.id)}>
              {server.connecting && <Spinner />}{server.isLocal ? 'Start' : 'Connect'}
            </Button>}
      </div>
      {server.lastError && <p className={styles.error} role="alert">{server.lastError}</p>}
      {expanded && (
        <div id={detailID} className={styles.detail}>
          {server.isLocal ? <LocalServerDetail server={server} /> : <ServerDetail server={server} />}
        </div>
      )}
    </section>
  )
}

function ServerDetail({ server }: { server: ServerEntry }) {
  const model = useModel()
  const [secret, setSecret] = useState('')
  const config = server.config
  const ids = useId()
  const update = (patch: Parameters<typeof model.servers.update>[1]) => model.servers.update(server.id, patch)
  const saveSecretAndConnect = () => {
    if (secret) model.servers.setSecret(server.id, secret)
    void model.servers.connect(server.id).then(() => setSecret(''))
  }
  return (
    <>
      <ListRow title="Name" htmlFor={`${ids}-name`} action={
        <TextField id={`${ids}-name`} value={config.name} placeholder={defaultServerName(config.serverURL) ?? 'New Server'}
          onChange={(name) => update({ name })} />
      } />
      <ListRow title="Server URL" htmlFor={`${ids}-url`}
        description="The Hermes dashboard’s address, e.g. a Tailscale HTTPS name."
        below={server.probeResult && <div className={styles.probe}>{server.probeResult}</div>}
        action={<>
          <TextField id={`${ids}-url`} value={config.serverURL} placeholder="https://hermes.example.ts.net"
            onChange={(serverURL) => update({ serverURL })} />
          <Button disabled={!server.hasURL} onClick={() => void model.servers.probe(server.id)}>Check Server</Button>
        </>} />
      <ListRow title="Sign-in method" htmlFor={`${ids}-method`} description={authModeCopy[config.authMode].help} action={
        <Select<AuthMode> id={`${ids}-method`} value={config.authMode}
          options={authModes.map((mode) => ({ value: mode, label: authModeCopy[mode].label }))}
          onChange={(authMode) => update({ authMode })} />
      } />
      {config.authMode === 'password' && (
        <>
          <ListRow title="Provider" htmlFor={`${ids}-provider`} action={
            <TextField id={`${ids}-provider`} value={config.provider} onChange={(provider) => update({ provider })} />
          } />
          <ListRow title="Username" htmlFor={`${ids}-user`} action={
            <TextField id={`${ids}-user`} value={config.username} autoComplete="username"
              onChange={(username) => update({ username })} />
          } />
        </>
      )}
      {config.authMode === 'browser'
        ? <ListRow title={authModeCopy.browser.secretLabel}
            description={server.isSignedInWithBrowser ? 'Signed in' : 'Not signed in'}
            action={<BrowserSignIn server={server} />} />
        : <ListRow title={authModeCopy[config.authMode].secretLabel} htmlFor={`${ids}-secret`}
            description={server.hasSecret ? 'Saved. Type a new one to replace it.' : undefined}
            action={<>
              <TextField id={`${ids}-secret`} type="password" value={secret} placeholder={server.hasSecret ? '••••••••' : ''}
                autoComplete={config.authMode === 'password' ? 'current-password' : 'off'} onChange={setSecret} />
              <Button disabled={!secret || !server.hasURL} onClick={saveSecretAndConnect}>Save</Button>
            </>} />}
      <RemoveRow server={server} />
    </>
  )
}

/** The browser sign-in: Sign In, then waiting with Cancel. */
function BrowserSignIn({ server }: { server: ServerEntry }) {
  const model = useModel()
  const abort = useRef<AbortController | undefined>(undefined)
  useEffect(() => () => abort.current?.abort(), [])
  if (server.signingIn) {
    return (
      <>
        <Spinner />
        <span className={styles.secondary}>Waiting for the browser…</span>
        <Button onClick={() => abort.current?.abort()}>Cancel</Button>
      </>
    )
  }
  return (
    <Button disabled={!server.hasURL} onClick={() => {
      abort.current = new AbortController()
      void model.servers.signInWithBrowser(server.id, abort.current.signal)
    }}>{server.isSignedInWithBrowser ? 'Sign In Again…' : 'Sign In with Browser…'}</Button>
  )
}

/** "This Mac" / "This PC": the Hermes the app runs. Nothing to fill in. */
function LocalServerDetail({ server }: { server: ServerEntry }) {
  const model = useModel()
  const connection = useSnapshot(server.connection)
  const isConnected = connection.link.phase === 'connected'
  return (
    <>
      <ListRow title="Hermes on this computer"
        description="Runs hermes serve on a free port, with a new token each time. It stops when you quit the app."
        action={isConnected && (
          <Button disabled={server.connecting} onClick={async () => {
            await model.servers.disconnect(server.id)
            await model.servers.connect(server.id)
          }}>Restart</Button>
        )} />
      <RemoveRow server={server} />
    </>
  )
}

/** Remove, confirmed in place. */
function RemoveRow({ server }: { server: ServerEntry }) {
  const model = useModel()
  const [confirming, setConfirming] = useState(false)
  const description: ReactNode = confirming
    ? (server.isLocal
        ? 'The app stops the Hermes it runs on this computer. Chats stay in Hermes.'
        : 'The app disconnects and forgets its sign-in. Chats stay on the server.')
    : undefined
  return (
    <ListRow title={confirming ? `Remove ${server.name}?` : 'Remove server'} description={description} action={confirming
      ? <>
          <Button onClick={() => setConfirming(false)}>Cancel</Button>
          <Button variant="destructive" onClick={() => void model.servers.remove(server.id)}>Remove</Button>
        </>
      : <Button variant="destructive" onClick={() => setConfirming(true)}>Remove…</Button>} />
  )
}
