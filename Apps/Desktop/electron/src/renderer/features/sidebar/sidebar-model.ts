import { SessionSidebar, type GatewayConnection, type SessionsREST } from '@talaria/hermes-core'
import type { TalariaBridge } from '../../../shared/bridge.ts'
import { useConnection, useModel, useSnapshot } from '../../app/hooks.ts'
import type { AppModel } from '../../app/model.ts'

/**
 * The sidebar's state above each server's connection (`SessionSidebar`): one per
 * connection, as cron's board, kept as long as the connection. What each keeps goes in
 * `sidebar.json` under its server's id.
 */
const sidebars = new WeakMap<GatewayConnection, SessionSidebar>()

export function sessionSidebar(bridge: TalariaBridge, connection: GatewayConnection, serverID: string | undefined): SessionSidebar {
  let found = sidebars.get(connection)
  if (!found) {
    const store = sidebarFile(bridge)
    found = new SessionSidebar({
      connection,
      rest: () => restOf(connection),
      serverKey: () => serverID,
      ...(serverID ? { store: { load: () => store.load(serverID), save: (value) => store.save(serverID, value) } } : {}),
    })
    sidebars.set(connection, found)
    void found.load()
  }
  return found
}

/** The current server's sidebar, re-rendering on its changes and on a change of server. */
export function useSessionSidebar(): SessionSidebar {
  const model = useModel()
  const connection = useConnection()
  const sidebar = sessionSidebar(model.bridge, connection, model.get().currentServerID)
  useSnapshot(sidebar)
  return sidebar
}

/** A server's sidebar, by the server's id (the rail draws every server's profiles). */
export function serverSidebar(model: AppModel, serverID: string): SessionSidebar | undefined {
  const connection = model.serverConnection(serverID)
  return connection ? sessionSidebar(model.bridge, connection, serverID) : undefined
}

/** The connection's dashboard REST, in the shape the sidebar's reads take. */
function restOf(connection: GatewayConnection): SessionsREST | undefined {
  const api = connection.dashboardAPI
  if (!api) return undefined
  return {
    send: async <T,>(method: Parameters<SessionsREST['send']>[0], path: string,
      options: { query?: Record<string, string | undefined>; body?: unknown; timeoutMs?: number } = {}) => {
      const query = Object.entries(options.query ?? {}).filter((pair): pair is [string, string] => pair[1] !== undefined)
      return await api.send(method, path, {
        query,
        ...(options.body !== undefined ? { body: options.body as never } : {}),
        ...(options.timeoutMs !== undefined ? { timeoutMs: options.timeoutMs } : {}),
      }) as T
    },
  }
}

/** `sidebar.json`: `{ servers: { [id]: kept } }`, read once, each server's part written in turn. */
interface SidebarFile {
  load(serverID: string): Promise<unknown>
  save(serverID: string, value: unknown): void
}

let file: SidebarFile | undefined

function sidebarFile(bridge: TalariaBridge): SidebarFile {
  if (file) return file
  let servers: Record<string, unknown> | undefined
  const read = bridge.sidebar.load().then((value) => {
    const kept = value && typeof value === 'object' ? (value as { servers?: unknown }).servers : undefined
    servers = kept && typeof kept === 'object' ? { ...(kept as Record<string, unknown>) } : {}
  }, () => { servers = {} })
  file = {
    load: async (serverID) => {
      await read
      return servers?.[serverID]
    },
    save: (serverID, value) => {
      void read.then(() => {
        servers = { ...servers, [serverID]: value }
        return bridge.sidebar.save({ servers })
      }).catch(() => {})
    },
  }
  return file
}

/** Tests: forgets the file read. */
export function resetSidebarFile(): void {
  file = undefined
}
