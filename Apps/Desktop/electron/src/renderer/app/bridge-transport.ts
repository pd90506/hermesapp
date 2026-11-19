import { TransportError, type HttpClient, type MessageTransport } from '@talaria/hermes-core'
import type { SocketEvent, TalariaBridge } from '../../shared/bridge.ts'

/** hermes-core's HTTP, sent by the main process (`window.talaria.http`). */
export function bridgeHttp(bridge: TalariaBridge): HttpClient {
  return {
    send: (request) => bridge.http.send(request).catch((error: unknown) => {
      // Electron wraps a main-process error as "Error invoking remote method '…': Error: …".
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(message.replace(/^Error invoking remote method '[^']*': (?:\w*Error: )?/, ''))
    }),
    reset: () => bridge.http.reset(),
  }
}

/** One gateway WebSocket, opened by the main process (`window.talaria.socket`). */
export class BridgeSocket implements MessageTransport {
  private id?: number
  private messageHandler?: (text: string) => void
  private closeHandler?: (error?: Error) => void
  private unsubscribe?: () => void
  private closed = false

  constructor(private readonly bridge: TalariaBridge, private readonly url: string) {}

  connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let opened = false
      this.unsubscribe = this.bridge.socket.onEvent((event: SocketEvent) => {
        if (event.id !== this.id) return
        if (event.type === 'open') {
          opened = true
          resolve()
        } else if (event.type === 'message') {
          this.messageHandler?.(event.data)
        } else {
          this.unsubscribe?.()
          const error = event.error ? new TransportError(event.error.kind, event.error.message) : undefined
          if (!opened) {
            reject(error ?? new TransportError('closed', 'closed before it opened'))
          } else if (!this.closed) {
            this.closed = true
            this.closeHandler?.(error)
          }
        }
      })
      this.bridge.socket.open(this.url).then((id) => { this.id = id }, reject)
    })
  }

  async send(text: string): Promise<void> {
    if (this.id === undefined || this.closed) throw new TransportError('closed', 'socket not open')
    await this.bridge.socket.send(this.id, text)
  }

  onMessage(handler: (text: string) => void): void {
    this.messageHandler = handler
  }

  onClose(handler: (error?: Error) => void): void {
    this.closeHandler = handler
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    if (this.id !== undefined) await this.bridge.socket.close(this.id)
  }
}
