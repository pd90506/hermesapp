import { builtinModules } from 'node:module'
import { defineConfig } from 'vite'

// The main process, bundled with what it uses (ws), so the packaged app needs no
// node_modules. ws's optional native speed-ups stay out; it runs without them.
export default defineConfig({
  // Node's entry points, not the browser stubs (ws's `browser` export throws).
  resolve: { conditions: ['node', 'require', 'default'], mainFields: ['main'] },
  build: {
    outDir: 'out/main',
    emptyOutDir: true,
    target: 'node22',
    minify: false,
    lib: { entry: 'src/main/main.ts', formats: ['cjs'], fileName: () => 'main.cjs' },
    rollupOptions: {
      external: ['electron', 'bufferutil', 'utf-8-validate', ...builtinModules, ...builtinModules.map((m) => `node:${m}`)],
    },
  },
})
