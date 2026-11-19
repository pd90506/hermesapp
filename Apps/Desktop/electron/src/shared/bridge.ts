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
  /** The first version's single server; read once, into `servers`. */
  server?: SavedServer
  /** Whether the profile rail shows (the Mac's `profileRailShown`). */
  railShown?: boolean
  /* K: settings and servers */
  /** The servers (hermes-core `ServerConfig`, JSON), without their secrets. */
  servers?: unknown[]
  /** Whether the app runs Hermes on this computer ("This Mac" / "This PC"). */
  localBackend?: boolean
  /** Settings ▸ Session Sources (hermes-core `SessionSourceSettings`). */
  sourceSettings?: unknown
  /** Settings ▸ Notifications (hermes-core `AlertPreferences`). */
  alertPreferences?: unknown
  /** The settings pane shown last. */
  settingsPane?: string
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
  /* K: settings and servers */
  /** Each server's password, token or sign-in, by server id, encrypted by the OS. */
  secrets: {
    load(id: string): Promise<{ value: string | null; available: boolean }>
    save(id: string, value: string | null): Promise<void>
  }
  /** Settings (an overlay in the main window, `features/settings`). */
  settingsWindow: {
    /** The Mac app menu's Settings… (⌘,) or Ctrl+, elsewhere: the renderer opens Settings. */
    onOpenRequest(handler: () => void): () => void
  }
  /** The browser sign-in's loopback listener (RFC 8252) and the system browser. */
  signIn: {
    /** Listens on 127.0.0.1 on a port the OS picks. */
    listen(): Promise<{ id: number; port: number }>
    /** The request target (`/callback?code=…`) the browser came back with. */
    callback(id: number): Promise<string>
    stop(id: number): Promise<void>
    /** Opens an http(s) page in the default browser. */
    openExternal(url: string): Promise<void>
  }
  /** The `hermes serve` the app runs on this computer. */
  localBackend: {
    available(): Promise<boolean>
    start(): Promise<{ port: number; token: string }>
    stop(): Promise<void>
    isRunning(): Promise<boolean>
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
  /* K: settings and servers */
  secretsLoad: 'talaria:secrets:load',
  secretsSave: 'talaria:secrets:save',
  settingsOpen: 'talaria:settings-window:open',
  signInListen: 'talaria:sign-in:listen',
  signInCallback: 'talaria:sign-in:callback',
  signInStop: 'talaria:sign-in:stop',
  signInOpen: 'talaria:sign-in:open',
  localBackendAvailable: 'talaria:local-backend:available',
  localBackendStart: 'talaria:local-backend:start',
  localBackendStop: 'talaria:local-backend:stop',
  localBackendRunning: 'talaria:local-backend:running',
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
