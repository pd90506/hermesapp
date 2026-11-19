import { useState, type FormEvent } from 'react'
import type { SavedServer } from '../../../shared/bridge.ts'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import styles from './ConnectPage.module.css'

const modes: { value: SavedServer['authMode']; label: string }[] = [
  { value: 'password', label: 'Password' },
  { value: 'accessToken', label: 'Access token' },
  { value: 'sessionToken', label: 'Session token' },
]

/**
 * Where the app points at a Hermes dashboard: its address and how to sign in, as the
 * Mac's connection settings (AuthMode). Shown at first launch and from the rail's
 * Settings button. The secret is kept by the OS (safeStorage), never in settings.json.
 */
export function ConnectPage() {
  const model = useModel()
  const app = useSnapshot(model)
  const saved = app.server
  const [serverURL, setServerURL] = useState(saved?.serverURL ?? '')
  const [authMode, setAuthMode] = useState<SavedServer['authMode']>(saved?.authMode ?? 'password')
  const [provider, setProvider] = useState(saved?.provider || 'basic')
  const [username, setUsername] = useState(saved?.username ?? '')
  const [secret, setSecret] = useState('')

  const ready = serverURL.trim() !== '' && secret !== '' && (authMode !== 'password' || username.trim() !== '')

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (!ready || app.connecting) return
    void model.connect({ serverURL: serverURL.trim(), authMode, provider: provider.trim() || 'basic', username: username.trim() }, secret)
  }

  return (
    <div className={styles.page}>
      <div className={styles.band} />
      <form className={styles.form} onSubmit={submit}>
        <h1 className={styles.title}>Connect to Hermes</h1>
        <p className={styles.hint}>The address of your Hermes dashboard and how you sign in to it.</p>
        <label className={styles.field}>
          <span className={styles.label}>Server</span>
          <input className={styles.input} value={serverURL} placeholder="https://hermes.example.com:9119"
            autoFocus spellCheck={false} onChange={(event) => setServerURL(event.target.value)} />
        </label>
        <label className={styles.field}>
          <span className={styles.label}>Sign in with</span>
          <select className={styles.input} value={authMode}
            onChange={(event) => setAuthMode(event.target.value as SavedServer['authMode'])}>
            {modes.map((mode) => <option key={mode.value} value={mode.value}>{mode.label}</option>)}
          </select>
        </label>
        {authMode === 'password' && (
          <>
            <label className={styles.field}>
              <span className={styles.label}>Provider</span>
              <input className={styles.input} value={provider} spellCheck={false}
                onChange={(event) => setProvider(event.target.value)} />
            </label>
            <label className={styles.field}>
              <span className={styles.label}>Username</span>
              <input className={styles.input} value={username} spellCheck={false} autoComplete="username"
                onChange={(event) => setUsername(event.target.value)} />
            </label>
          </>
        )}
        <label className={styles.field}>
          <span className={styles.label}>{authMode === 'password' ? 'Password' : 'Token'}</span>
          <input className={styles.input} type="password" value={secret}
            autoComplete={authMode === 'password' ? 'current-password' : 'off'}
            onChange={(event) => setSecret(event.target.value)} />
        </label>
        {app.connectError && <p className={styles.error} role="alert">{app.connectError}</p>}
        <div className={styles.actions}>
          {saved && (
            <button type="button" className={styles.button} onClick={() => void model.forgetServer()}>Forget server</button>
          )}
          <span className={styles.spacer} />
          {saved && (
            <button type="button" className={styles.button} onClick={() => model.showConnectPage(false)}>Back</button>
          )}
          <button type="submit" className={styles.primary} disabled={!ready || app.connecting}>
            {app.connecting ? 'Connecting…' : 'Connect'}
          </button>
        </div>
      </form>
    </div>
  )
}
