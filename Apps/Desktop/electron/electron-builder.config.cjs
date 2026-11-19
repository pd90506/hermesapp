// Packaging. Everything the app runs is bundled into out/ (see the vite configs), so
// no node_modules go into the package.
/** @type {import('electron-builder').Configuration} */
module.exports = {
  appId: 'com.example.hermesapp.desktop',
  productName: 'Talaria',
  directories: { output: 'dist', buildResources: 'resources' },
  files: ['out/**', 'package.json'],
  npmRebuild: false,
  asar: true,
  // Both from the Mac app's icon (Apps/Shared/AppIcon.icon) by scripts/make-icons.py.
  win: { target: ['dir'], icon: 'resources/icon.ico' },
  mac: { target: ['dir'], icon: 'resources/icon.png', category: 'public.app-category.productivity' },
}
