// Development: the renderer from Vite's dev server (hot reload), the main process and
// preload built once, then Electron pointed at the server. Ctrl+C stops both.
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { build, createServer } from 'vite'

const require = createRequire(import.meta.url)
await build({ configFile: 'vite.main.config.mts', logLevel: 'warn' })
await build({ configFile: 'vite.preload.config.mts', logLevel: 'warn' })
const server = await createServer({ configFile: 'vite.config.mts' })
await server.listen()
const url = server.resolvedUrls?.local[0] ?? 'http://127.0.0.1:5175/'

const electron = spawn(require('electron'), ['.'], {
  stdio: 'inherit',
  env: { ...process.env, TALARIA_DEV_SERVER: url },
})
electron.on('exit', async (code) => {
  await server.close()
  process.exit(code ?? 0)
})
