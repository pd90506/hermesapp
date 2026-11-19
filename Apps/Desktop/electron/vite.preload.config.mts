import { defineConfig } from 'vite'

// The preload: CommonJS, as a sandboxed renderer's preload must be.
export default defineConfig({
  build: {
    outDir: 'out/preload',
    emptyOutDir: true,
    target: 'node22',
    minify: false,
    lib: { entry: 'src/preload/preload.ts', formats: ['cjs'], fileName: () => 'preload.cjs' },
    rollupOptions: { external: ['electron'] },
  },
})
