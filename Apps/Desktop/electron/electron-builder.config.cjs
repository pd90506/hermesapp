// Packaging. Everything the app runs is bundled into out/ (see the vite configs), so
// no node_modules go into the package.
/** @type {import('electron-builder').Configuration} */
module.exports = {
  appId: 'com.example.hermesapp.desktop',
  productName: 'Talaria',
  directories: { output: 'dist', buildResources: 'build' },
  files: ['out/**', 'package.json'],
  npmRebuild: false,
  asar: true,
  win: { target: ['dir'] },
  mac: { target: ['dir'], category: 'public.app-category.productivity' },
}
