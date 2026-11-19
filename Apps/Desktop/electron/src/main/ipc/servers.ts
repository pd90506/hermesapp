import { ipcMain, shell } from 'electron'
import { createServer, type Server } from 'node:http'
import { isNativeCallback } from '@talaria/hermes-core'
import { IPC } from '../../shared/bridge.ts'
import { loadServerSecret, saveServerSecret } from '../store.ts'

/**
 * Servers (K): each server's secret, and the browser sign-in's loopback end (RFC 8252,
 * as Hermes Desktop's `native-oauth-login.ts` and the Mac's `LoopbackRedirect`): an HTTP
 * listener on 127.0.0.1, on a port the OS picks, that waits for the browser to come back
 * to `/callback` and answers it with a short page. Other requests (a favicon) get a 404.
 */
interface Listener {
  server: Server
  callback: Promise<string>
  stop(): void
}

const listeners = new Map<number, Listener>()
let nextID = 1

const page = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">' +
  '<title>Talaria</title></head><body style="font: 16px system-ui, sans-serif; text-align: center; padding-top: 20vh">' +
  'Signed in. You can close this page and go back to Talaria.</body></html>'

function listen(): Promise<{ id: number; port: number }> {
  return new Promise((resolve, reject) => {
    let settle!: (target: string) => void
    let fail!: (error: Error) => void
    const callback = new Promise<string>((done, refuse) => { settle = done; fail = refuse })
    callback.catch(() => {})
    const server = createServer((request, response) => {
      const target = request.url ?? '/'
      if (request.method === 'GET' && target.startsWith('/') && isNativeCallback(target)) {
        response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', Connection: 'close' })
        response.end(page)
        settle(target)
      } else {
        response.writeHead(404, { 'Content-Length': '0', Connection: 'close' })
        response.end()
      }
    })
    const id = nextID++
    const stop = () => {
      fail(new Error('stopped'))
      server.close()
      server.closeAllConnections()
      listeners.delete(id)
    }
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (!address || typeof address === 'string') {
        server.close()
        reject(new Error('No loopback port'))
        return
      }
      listeners.set(id, { server, callback, stop })
      // Never left listening: 10 minutes, as long as the sign-in waits.
      setTimeout(stop, 600_000).unref()
      resolve({ id, port: address.port })
    })
  })
}

export function registerServers(): void {
  ipcMain.handle(IPC.secretsLoad, (_event, id: string) => loadServerSecret(id))
  ipcMain.handle(IPC.secretsSave, (_event, id: string, value: string | null) => saveServerSecret(id, value))
  ipcMain.handle(IPC.signInListen, () => listen())
  ipcMain.handle(IPC.signInCallback, (_event, id: number) => {
    const listener = listeners.get(id)
    if (!listener) throw new Error('Not listening')
    return listener.callback
  })
  ipcMain.handle(IPC.signInStop, (_event, id: number) => listeners.get(id)?.stop())
  ipcMain.handle(IPC.signInOpen, async (_event, url: string) => {
    if (!/^https?:\/\//i.test(url)) throw new Error('Only http(s) pages')
    await shell.openExternal(url)
  })
}
