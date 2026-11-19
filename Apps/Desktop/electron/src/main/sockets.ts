import type { WebContents } from 'electron'
import WebSocket from 'ws'
import { IPC, type SocketEvent } from '../shared/bridge.ts'

/**
 * The gateway's WebSockets, opened in the main process with `ws`, which sends no
 * `Origin` (the dashboard allows a client without one, `web_server_chat.py:167-194`).
 * Frames go to and from the renderer that opened them.
 */
export class Sockets {
  private nextID = 0
  private readonly open = new Map<number, { socket: WebSocket; owner: WebContents }>()

  connect(owner: WebContents, url: string): number {
    const parsed = new URL(url)
    if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') throw new Error('Only ws(s) sockets')
    const id = ++this.nextID
    const socket = new WebSocket(url, { handshakeTimeout: 15_000, maxPayload: 64 * 1024 * 1024 })
    this.open.set(id, { socket, owner })
    const emit = (event: SocketEvent) => {
      if (!owner.isDestroyed()) owner.send(IPC.socketEvent, event)
    }
    let failure: SocketEvent & { type: 'close' } | undefined
    socket.on('open', () => emit({ id, type: 'open' }))
    socket.on('message', (data, isBinary) => {
      if (!isBinary) emit({ id, type: 'message', data: data.toString() })
    })
    socket.on('unexpected-response', (_request, response) => {
      // The gateway refuses bad tickets and host/origin mismatches before accepting:
      // a plain HTTP status on the upgrade.
      failure = { id, type: 'close', error: { kind: 'handshakeFailed', message: `HTTP ${response.statusCode}` } }
      socket.terminate()
    })
    socket.on('error', (error) => {
      failure ??= { id, type: 'close', error: { kind: 'network', message: error.message } }
    })
    socket.on('close', (code, reason) => {
      this.open.delete(id)
      if (failure) return emit(failure)
      const deliberate = code === 1000 || code === 1005
      emit(deliberate ? { id, type: 'close' } : {
        id, type: 'close', error: { kind: 'closed', message: `closed (${code}${reason.length ? `: ${reason}` : ''})` },
      })
    })
    owner.once('destroyed', () => this.close(id))
    return id
  }

  send(id: number, text: string): void {
    const entry = this.open.get(id)
    if (!entry || entry.socket.readyState !== WebSocket.OPEN) throw new Error('socket not open')
    entry.socket.send(text)
  }

  close(id: number): void {
    const entry = this.open.get(id)
    if (!entry) return
    if (entry.socket.readyState === WebSocket.CONNECTING) entry.socket.terminate()
    else entry.socket.close(1000)
  }
}
