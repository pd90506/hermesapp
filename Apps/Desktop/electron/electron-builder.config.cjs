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
  // The Flutter app's icon (Apps/Desktop/talaria/windows/runner/resources/app_icon.ico).
  win: { target: ['dir'], icon: 'resources/icon.ico' },
  mac: { target: ['dir'], category: 'public.app-category.productivity' },
}
