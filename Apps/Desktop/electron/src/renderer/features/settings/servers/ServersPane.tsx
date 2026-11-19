import {
  authModeCopy, authModes, defaultServerName, localServerName, type AuthMode, type ServerEntry,
} from '@talaria/hermes-core'
import { useEffect, useId, useRef, useState } from 'react'
import { useModel, useServers, useSnapshot } from '../../../app/hooks.ts'
import { Icon } from '../../../ui/Icon.tsx'
import { Button, Form, Note, Row, Segmented, Select, Spinner, TextField, Toggle } from '../ui/Form.tsx'
import { linkStatus } from './status.ts'
import styles from './ServersPane.module.css'

/**
 * Settings ▸ Servers, as the Mac's `ServersSettingsPane` (laid out like Mail's
 * Accounts): the servers in a list with add and remove under it and the local Hermes
 * switch, and the one picked beside it, its details on two tabs.
 */
export function ServersPane() {
  const model = useModel()
  const { servers, runsLocalBackend } = useServers()
  const [selectedID, setSelectedID] = useState<string | undefined>()
  const [confirmsRemoval, setConfirmsRemoval] = useState(false)
  const [localAvailable, setLocalAvailable] = useState<boolean | undefined>()
  const selected = servers.find((entry) => entry.id === selectedID) ?? servers[0]

  useEffect(() => {
    // Nothing to edit yet: start with a blank server.
    if (servers.length === 0) setSelectedID(model.servers.add())
    void model.bridge.localBackend.available().then(setLocalAvailable, () => setLocalAvailable(false))
    // Only when the pane opens.
  }, [])

  useEffect(() => setConfirmsRemoval(false), [selected?.id])

  return (
    <div className={styles.pane}>
      <div className={styles.sidebar}>
        <ul className={styles.list} role="listbox" aria-label="Servers">
          {servers.map((server) => (
            <ServerRow key={server.id} server={server} selected={server.id === selected?.id}
              onSelect={() => setSelectedID(server.id)} />
          ))}
        </ul>
        <div className={styles.listButtons}>
          <button type="button" className={styles.listButton} title="Add Server" aria-label="Add Server"
            onClick={() => setSelectedID(model.servers.add())}><Icon name="add" /></button>
          <button type="button" className={styles.listButton} title="Remove Server" aria-label="Remove Server"
            disabled={!selected} onClick={() => setConfirmsRemoval(true)}><Icon name="remove" /></button>
        </div>
        {(localAvailable || runsLocalBackend) && (
          <Toggle label={`Run Hermes on ${localServerName(model.bridge.platform).replace('This', 'this')}`}
            checked={runsLocalBackend}
            onChange={(on) => {
              void model.servers.setRunsLocalBackend(on)
            }} />
        )}
      </div>
      <div className={styles.detail}>
        {!selected && <p className={styles.empty}>No Server Selected</p>}
        {selected && confirmsRemoval && (
          <RemovalConfirmation server={selected} onCancel={() => setConfirmsRemoval(false)}
            onRemove={() => {
              setConfirmsRemoval(false)
              void model.servers.remove(selected.id)
            }} />
        )}
        {selected && !confirmsRemoval && (selected.isLocal
          ? <LocalServerDetail key={selected.id} server={selected} />
          : <ServerDetail key={selected.id} server={selected} />)}
      </div>
    </div>
  )
}

function ServerRow({ server, selected, onSelect }: { server: ServerEntry; selected: boolean; onSelect: () => void }) {
  return (
    <li role="option" aria-selected={selected} className={styles.row} data-selected={selected || undefined} onClick={onSelect}>
      <span className={styles.rowIcon}><Icon name={server.isLocal ? 'computer' : 'globe'} /></span>
      <span className={styles.rowText}>
        <span className={styles.rowName}>{server.name}</span>
        <span className={styles.rowKind}>{server.isLocal ? 'Local' : 'Hermes Dashboard'}</span>
      </span>
    </li>
  )
}

function RemovalConfirmation({ server, onCancel, onRemove }: { server: ServerEntry; onCancel: () => void; onRemove: () => void }) {
  return (
    <div className={styles.box} role="alertdialog" aria-label={`Remove ${server.name}?`}>
      <div className={styles.confirm}>
        <p className={styles.confirmTitle}>Remove {server.name}?</p>
        <p className={styles.confirmText}>
          {server.isLocal
            ? 'The app stops the Hermes it runs on this computer. Chats stay in Hermes.'
            : 'The app disconnects from it and forgets its sign-in. Chats stay on the server.'}
        </p>
        <div className={styles.confirmButtons}>
          <Button onClick={onCancel}>Cancel</Button>
          <Button primary destructive onClick={onRemove}>{server.isLocal ? 'Stop and Remove' : 'Remove'}</Button>
        </div>
      </div>
    </div>
  )
}

/** "Connected" with a coloured dot, as Mail shows an account's status. */
function ServerStatus({ server }: { server: ServerEntry }) {
  const connection = useSnapshot(server.connection)
  const status = linkStatus(connection.link)
  return (
    <Row label="Status">
      <span className={styles.status}>
        <span>{status.text}</span>
        <span className={styles.dot} data-tone={status.tone} aria-hidden="true" />
      </span>
    </Row>
  )
}

/** The last connect's error, and the connect buttons, under a server's details. */
function ActionBar({ server, children }: { server: ServerEntry; children: React.ReactNode }) {
  return (
    <div className={styles.actions}>
      {server.lastError
        ? <p className={styles.error} role="alert">{server.lastError}</p>
        : <span className={styles.spacer} />}
      {children}
    </div>
  )
}

type Page = 'information' | 'signIn'

function ServerDetail({ server }: { server: ServerEntry }) {
  const model = useModel()
  const connection = useSnapshot(server.connection)
  const [page, setPage] = useState<Page>('information')
  const [secret, setSecret] = useState('')
  const isConnected = connection.link.phase === 'connected'
  const config = server.config
  const ids = useId()
  const connect = () => {
    if (secret) model.servers.setSecret(server.id, secret)
    void model.servers.connect(server.id).then(() => setSecret(''))
  }
  return (
    <>
      <div className={styles.box}>
        <div className={styles.boxControl}>
          <Segmented label="Page" value={page} onChange={setPage} options={[
            { value: 'information', label: 'Server Information' },
            { value: 'signIn', label: 'Sign-in' },
          ]} />
        </div>
        <div className={styles.boxContent}>
          {page === 'information' ? (
            <Form>
              <ServerStatus server={server} />
              <Row label="Name" htmlFor={`${ids}-name`}>
                <TextField id={`${ids}-name`} value={config.name} placeholder={defaultServerName(config.serverURL) ?? 'New Server'}
                  onChange={(name) => model.servers.update(server.id, { name })} />
              </Row>
              <Row label="Server URL" htmlFor={`${ids}-url`}>
                <TextField id={`${ids}-url`} value={config.serverURL} placeholder="https://hermes.example.ts.net"
                  onChange={(serverURL) => model.servers.update(server.id, { serverURL })} />
              </Row>
              <Row>
                <Note>The address of the Hermes dashboard (the same one the desktop app uses), e.g. a Tailscale HTTPS name.</Note>
                <span className={styles.inline}>
                  <Button disabled={!server.hasURL} onClick={() => void model.servers.probe(server.id)}>Check Server</Button>
                  {server.probeResult && <span className={styles.probe}>{server.probeResult}</span>}
                </span>
              </Row>
            </Form>
          ) : (
            <Form>
              <Row label="Method" htmlFor={`${ids}-method`}>
                <Select<AuthMode> id={`${ids}-method`} value={config.authMode}
                  options={authModes.map((mode) => ({ value: mode, label: authModeCopy[mode].label }))}
                  onChange={(authMode) => model.servers.update(server.id, { authMode })} />
              </Row>
              {config.authMode === 'password' && (
                <>
                  <Row label="Provider" htmlFor={`${ids}-provider`}>
                    <TextField id={`${ids}-provider`} value={config.provider}
                      onChange={(provider) => model.servers.update(server.id, { provider })} />
                  </Row>
                  <Row label="Username" htmlFor={`${ids}-user`}>
                    <TextField id={`${ids}-user`} value={config.username} autoComplete="username"
                      onChange={(username) => model.servers.update(server.id, { username })} />
                  </Row>
                </>
              )}
              {config.authMode === 'browser' ? (
                <Row label={authModeCopy.browser.secretLabel}>
                  <BrowserSignIn server={server} />
                </Row>
              ) : (
                <Row label={authModeCopy[config.authMode].secretLabel} htmlFor={`${ids}-secret`}>
                  <TextField id={`${ids}-secret`} type="password" value={secret}
                    placeholder={server.hasSecret ? 'Saved' : ''}
                    autoComplete={config.authMode === 'password' ? 'current-password' : 'off'}
                    onChange={setSecret} />
                </Row>
              )}
              {authModeCopy[config.authMode].help && (
                <Row><Note>{authModeCopy[config.authMode].help}</Note></Row>
              )}
            </Form>
          )}
        </div>
      </div>
      <ActionBar server={server}>
        {isConnected && <Button onClick={() => void model.servers.disconnect(server.id)}>Disconnect</Button>}
        <Button primary disabled={!server.hasURL || server.connecting} onClick={connect}>
          {server.connecting && <Spinner />}
          {isConnected ? 'Reconnect' : 'Connect'}
        </Button>
      </ActionBar>
    </>
  )
}

/** The browser sign-in (the Mac's `BrowserSignInButton`): Sign In, then waiting with Cancel. */
function BrowserSignIn({ server }: { server: ServerEntry }) {
  const model = useModel()
  const abort = useRef<AbortController | undefined>(undefined)
  useEffect(() => () => abort.current?.abort(), [])
  if (server.signingIn) {
    return (
      <span className={styles.inline}>
        <Spinner />
        <span className={styles.secondary}>Waiting for the browser…</span>
        <Button onClick={() => abort.current?.abort()}>Cancel</Button>
      </span>
    )
  }
  return (
    <span className={styles.inline}>
      <Button disabled={!server.hasURL} onClick={() => {
        abort.current = new AbortController()
        void model.servers.signInWithBrowser(server.id, abort.current.signal)
      }}>{server.isSignedInWithBrowser ? 'Sign In Again…' : 'Sign In with Browser…'}</Button>
      <span className={server.isSignedInWithBrowser ? styles.signedIn : styles.secondary}>
        {server.isSignedInWithBrowser ? 'Signed in' : 'Not signed in'}
      </span>
    </span>
  )
}

/** "This Mac" / "This PC": the Hermes the app runs. Nothing to fill in. */
function LocalServerDetail({ server }: { server: ServerEntry }) {
  const model = useModel()
  const connection = useSnapshot(server.connection)
  const isConnected = connection.link.phase === 'connected'
  return (
    <>
      <div className={styles.box}>
        <div className={styles.boxContent}>
          <Form>
            <ServerStatus server={server} />
            {isConnected && <Row label="Address"><span className={styles.selectable}>{server.config.serverURL}</span></Row>}
            <Row>
              <Note>The app runs hermes serve on this computer, as Hermes Desktop does: on a free port, with a new token each time. It stops when you quit the app.</Note>
            </Row>
          </Form>
        </div>
      </div>
      <ActionBar server={server}>
        {isConnected && <Button onClick={() => void model.servers.disconnect(server.id)}>Stop Hermes</Button>}
        <Button primary disabled={server.connecting} onClick={async () => {
          if (isConnected) await model.servers.disconnect(server.id)
          await model.servers.connect(server.id)
        }}>
          {server.connecting && <Spinner />}
          {isConnected ? 'Restart Hermes' : 'Start Hermes'}
        </Button>
      </ActionBar>
    </>
  )
}
