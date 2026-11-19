import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// The renderer: React, served from out/renderer by the main process.
export default defineConfig({
  root: 'src/renderer',
  base: './',
  plugins: [react()],
  css: {
    modules: { localsConvention: 'camelCaseOnly' },
  },
  build: {
    outDir: '../../out/renderer',
    emptyOutDir: true,
    target: 'chrome140',
  },
  server: { host: '127.0.0.1', port: 5175, strictPort: true },
  test: {
    root: '.',
    include: ['tests/**/*.test.{ts,tsx}'],
    environment: 'jsdom',
    css: { modules: { classNameStrategy: 'non-scoped' } },
  },
})
