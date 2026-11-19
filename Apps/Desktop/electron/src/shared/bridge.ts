/**
 * The typed capability bridge between the renderer and the main process: the only
 * native power the renderer has (`window.talaria`, set up by the preload). Platform
 * differences stay on the main side of it.
 */
import type { AppearanceSettingsJSON, MarkdownColorsJSON } from '@talaria/hermes-core'

export type Platform = 'windows' | 'mac' | 'linux'

export interface BridgeHttpRequest {
  method: 'GET' | 'POST' | 'PUT' | 'DELETE'
  url: string
  headers?: Record<string, string>
  body?: string
  timeoutMs?: number
}

export interface BridgeHttpResponse {
  status: number
  body: string
}

export type SocketEvent =
  | { id: number; type: 'open' }
  | { id: number; type: 'message'; data: string }
  /** `error` set when the socket failed or the server refused the upgrade. */
  | { id: number; type: 'close'; error?: { kind: 'handshakeFailed' | 'network' | 'closed'; message: string } }

export interface Appearance {
  dark: boolean
  /** The system accent colour, `#rrggbb`, when the platform has one. */
  accent?: string
}

/** The saved server (non-secret); the password or token is kept apart, encrypted. */
export interface SavedServer {
  serverURL: string
  authMode: 'password' | 'accessToken' | 'sessionToken'
  provider: string
  username: string
}

export interface SavedSettings {
  server?: SavedServer
  /** Whether the profile rail shows (the Mac's `profileRailShown`). */
  railShown?: boolean
  /** Settings ▸ Appearance: the look and the text sizes (HermesKit's `AppearanceSettings`). */
  appearance?: AppearanceSettingsJSON
  /** The colour theme and Markdown colours (HermesKit's `MarkdownColors`; its preset is the theme). */
  markdownColors?: MarkdownColorsJSON
}

export interface TalariaBridge {
  platform: Platform
  http: {
    send(request: BridgeHttpRequest): Promise<BridgeHttpResponse>
    /** Forgets the dashboard cookies. */
    reset(): Promise<void>
  }
  socket: {
    open(url: string): Promise<number>
    send(id: number, text: string): Promise<void>
    close(id: number): Promise<void>
    onEvent(handler: (event: SocketEvent) => void): () => void
  }
  settings: {
    load(): Promise<SavedSettings>
    save(settings: SavedSettings): Promise<void>
  }
  secret: {
    /** The server's password or token, or null; `available` false when the OS store is locked. */
    load(): Promise<{ value: string | null; available: boolean }>
    save(value: string | null): Promise<void>
  }
  appearance: {
    get(): Promise<Appearance>
    onChange(handler: (appearance: Appearance) => void): () => void
    /** Colours the Windows caption buttons to match the page. */
    setCaptionColors(colors: { symbol: string }): void
  }
  links: {
    /** Opens a web or mail address in the system's browser or mail app; false when refused. */
    open(url: string): Promise<boolean>
  },
  theme: {
    /** Light, dark or the system's look for the whole app (`nativeTheme.themeSource`). */
    setMode(mode: AppearanceMode): void
  }
}

export type AppearanceMode = 'system' | 'light' | 'dark'

export const IPC = {
  httpSend: 'talaria:http:send',
  httpReset: 'talaria:http:reset',
  socketOpen: 'talaria:socket:open',
  socketSend: 'talaria:socket:send',
  socketClose: 'talaria:socket:close',
  socketEvent: 'talaria:socket:event',
  settingsLoad: 'talaria:settings:load',
  settingsSave: 'talaria:settings:save',
  secretLoad: 'talaria:secret:load',
  secretSave: 'talaria:secret:save',
  appearanceGet: 'talaria:appearance:get',
  appearanceChanged: 'talaria:appearance:changed',
  captionColors: 'talaria:caption:colors',
  linksOpen: 'talaria:links:open',
  themeSetMode: 'talaria:theme:set-mode',
} as const

/** The window's geometry the renderer lays out around, set by the preload as CSS variables. */
export interface FrameGeometry {
  /** Height of the title band: the window drags by it. */
  titleBandHeight: number
  /** Width the caption buttons (Windows) take at the band's right end. */
  captionWidth: number
  /** Width the traffic lights (Mac) take at the band's left end. */
  trafficLightsWidth: number
}

export function frameGeometry(platform: Platform): FrameGeometry {
  switch (platform) {
    // Windows 11's caption buttons: 46 px each, three of them; the band is the
    // Flutter app's 48 px (native_frame.h), as tall as WinUI's tall title bar.
    case 'windows': return { titleBandHeight: 48, captionWidth: 138, trafficLightsWidth: 0 }
    // A unified toolbar's height on macOS 26 (52 pt); the traffic lights sit in it
    // (trafficLightPosition below) and take 78 pt with their margins.
    case 'mac': return { titleBandHeight: 52, captionWidth: 0, trafficLightsWidth: 78 }
    case 'linux': return { titleBandHeight: 48, captionWidth: 138, trafficLightsWidth: 0 }
  }
}
