/**
 * A Hermes backend on this computer that the app starts and stops itself, as Hermes
 * Desktop does and the Mac app's `LocalBackend` (HermesKit): `hermes serve` on a loopback
 * port the OS picks, signed in with a token made for each start. The pure parts; the
 * main process spawns it (`src/main/ipc/local-backend.ts`).
 *
 * - `--isolated`: without it, `hermes serve` attaches to a backend already serving this
 *   host and exits instead of binding (`hermes_cli/main_dashboard.py:893-935`).
 * - `HERMES_DASHBOARD_SESSION_TOKEN`: the token the backend accepts as `?token=`
 *   (`hermes_cli/web_server.py:380-383`).
 * - `HERMES_PARENT_PID`: the backend exits soon after the app does, even after a crash
 *   (`hermes_cli/web_server_lifecycle.py:326-365`).
 * - The port: printed as `HERMES_BACKEND_READY port=<n>` once bound
 *   (`apps/desktop/electron/backend-ready.ts:3-12`).
 */
export interface LocalBackendLaunch {
  executable: string
  arguments: string[]
  environment: Record<string, string | undefined>
}

export type LocalPlatform = 'windows' | 'mac' | 'linux'

/** The server id of "This Mac" / "This PC" (HermesKit's `ServerConnection.localID`). */
export const localServerID = '00000000-0000-0000-0000-00000000AC01'

/** "This Mac" on macOS, "This PC" elsewhere. */
export function localServerName(platform: LocalPlatform): string {
  return platform === 'mac' ? 'This Mac' : 'This PC'
}

/**
 * Where a `hermes` install lands, besides PATH (an app opened from the Finder or the Start
 * menu may not get the user's PATH). macOS and Linux as HermesKit's `installDirectories`;
 * Windows as Hermes Desktop's user-bin launchers and venv shims
 * (`updater-process.ts:userBinLaunchers`, `windows-remote-lifecycle.ts:130-155`).
 */
export function hermesCandidates(platform: LocalPlatform, env: { home: string; localAppData?: string; hermesHome?: string; path?: string }): string[] {
  if (platform === 'windows') {
    const join = (...parts: string[]) => parts.join('\\')
    const hermesHome = env.hermesHome || (env.localAppData ? join(env.localAppData, 'hermes') : '')
    const fixed = hermesHome ? [
      join(hermesHome, 'bin', 'hermes.exe'),
      join(hermesHome, 'hermes-agent', 'venv', 'Scripts', 'hermes.exe'),
    ] : []
    fixed.push(join(env.home, 'hermes-agent', '.venv', 'Scripts', 'hermes.exe'))
    const onPath = (env.path ?? '').split(';').filter(Boolean).map((dir) => join(dir.replace(/\\+$/, ''), 'hermes.exe'))
    return unique([...fixed, ...onPath])
  }
  const dirs = [`${env.home}/.local/bin`, `${env.home}/.hermes/hermes-agent/.hermes/bin`, '/opt/homebrew/bin', '/usr/local/bin']
  const onPath = (env.path ?? '').split(':').filter(Boolean)
  return unique([...dirs, ...onPath].map((dir) => `${dir.replace(/\/+$/, '')}/hermes`))
}

function unique(items: string[]): string[] {
  return [...new Set(items)]
}

/** What to run for `token` (HermesKit's `LocalBackend.launch`). */
export function localBackendLaunch(platform: LocalPlatform, hermes: string, token: string, parentPID: number,
  environment: Record<string, string | undefined>, home: string): LocalBackendLaunch {
  const env: Record<string, string | undefined> = { ...environment }
  env.HERMES_DASHBOARD_SESSION_TOKEN = token
  env.HERMES_PARENT_PID = String(parentPID)
  // A marker without a matching nonce disarms the watchdog (web_server_lifecycle.py:345-353).
  delete env.HERMES_PARENT_START_MARKER
  delete env.HERMES_PARENT_NONCE
  if (platform !== 'windows') {
    // Tools Hermes runs (git, node, …) are usually in the install directories too.
    const path = (env.PATH ?? '/usr/bin:/bin:/usr/sbin:/sbin').split(':')
    const extra = hermesCandidates(platform, { home }).map((file) => file.slice(0, file.lastIndexOf('/')))
      .filter((dir) => !path.includes(dir))
    env.PATH = [...extra, ...path].join(':')
  }
  return {
    executable: hermes,
    arguments: ['serve', '--host', '127.0.0.1', '--port', '0', '--isolated'],
    environment: env,
  }
}

/**
 * The port in the backend's output, once it has said it. Matched on a word boundary:
 * stderr chunks can run into the line without a newline (`backend-ready.ts:7-12`).
 */
export function readyPort(output: string): number | undefined {
  for (const marker of ['HERMES_BACKEND_READY port=', 'HERMES_DASHBOARD_READY port=']) {
    let from = 0
    for (;;) {
      const at = output.indexOf(marker, from)
      if (at < 0) break
      from = at + marker.length
      if (at > 0 && /[A-Za-z0-9_]/.test(output[at - 1]!)) continue
      const digits = /^\d+/.exec(output.slice(from))?.[0]
      const port = digits ? Number(digits) : NaN
      if (port >= 1 && port <= 65535) return port
    }
  }
  return undefined
}

/** The last lines of the backend's output, for an error. */
export function outputTail(output: string): string {
  const lines = output.split(/\r?\n/).filter((line) => line.trim() !== '').slice(-3).join('\n')
  return lines ? `\n${lines}` : ''
}
