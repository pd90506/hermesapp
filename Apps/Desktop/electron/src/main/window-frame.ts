import { nativeTheme, type BrowserWindowConstructorOptions } from 'electron'
import { release } from 'node:os'
import { frameGeometry, type Platform } from '../shared/bridge.ts'

/** Windows 11 22H2, the first build with the Mica system backdrop. */
const micaMinBuild = 22621

export function currentPlatform(): Platform {
  return process.platform === 'win32' ? 'windows' : process.platform === 'darwin' ? 'mac' : 'linux'
}

function windowsBuild(): number {
  return Number(release().split('.')[2] ?? 0)
}

export function captionSymbolColor(dark: boolean): string {
  // WinUI's caption glyphs: TextFillColorPrimary.
  return dark ? '#ffffff' : '#1a1a1a'
}

/**
 * The window frame each platform draws itself, as deepseek-harness and Hermes Desktop
 * set it up (docs/desktop-electron.md):
 * - Windows: no title bar, the system's caption buttons over the page's top right
 *   (Window Controls Overlay, with Snap layouts), and Mica under the page. Electron
 *   treats a window with a backdrop material as translucent, so no backgroundColor.
 * - macOS: the traffic lights inside the sidebar's title band, and the sidebar's
 *   vibrancy under the page; 'active' keeps it when the window is not key.
 */
export function windowFrameOptions(platform: Platform): BrowserWindowConstructorOptions {
  const geometry = frameGeometry(platform)
  const dark = nativeTheme.shouldUseDarkColors
  switch (platform) {
    case 'windows': {
      const mica = windowsBuild() >= micaMinBuild
      return {
        titleBarStyle: 'hidden',
        titleBarOverlay: { color: '#00000000', symbolColor: captionSymbolColor(dark), height: geometry.titleBandHeight },
        ...(mica ? { backgroundMaterial: 'mica' as const } : { backgroundColor: dark ? '#202020' : '#f3f3f3' }),
      }
    }
    case 'mac':
      return {
        titleBarStyle: 'hiddenInset',
        // Centred in the 52 pt band, 20 pt in from the edge, as AppKit places them
        // in a window with a unified toolbar.
        trafficLightPosition: { x: 20, y: 18 },
        vibrancy: 'sidebar',
        visualEffectState: 'active',
      }
    case 'linux':
      return {
        titleBarStyle: 'hidden',
        titleBarOverlay: { color: '#00000000', symbolColor: captionSymbolColor(dark), height: geometry.titleBandHeight },
        backgroundColor: dark ? '#202020' : '#f3f3f3',
      }
  }
}
