import { listedSources, normalizedSource } from '../bots.ts'

/**
 * Which session sources the lists hide (HermesKit's `SessionSourceSettings`), kept across
 * launches. Only `listedSources` (desktop, tui) can show at all; this hides those too.
 */
export interface SessionSourceSettings {
  hiddenSources: string[]
}

export const defaultSourceSettings: SessionSourceSettings = { hiddenSources: [] }

export function decodeSourceSettings(value: unknown): SessionSourceSettings {
  const hidden = (value as { hiddenSources?: unknown } | undefined)?.hiddenSources
  if (!Array.isArray(hidden)) return defaultSourceSettings
  return { hiddenSources: hidden.filter((item): item is string => typeof item === 'string').map((item) => normalizedSource(item) ?? item) }
}

export function isSourceHidden(settings: SessionSourceSettings, source: string): boolean {
  return settings.hiddenSources.includes(normalizedSource(source) ?? source)
}

export function setSourceHidden(settings: SessionSourceSettings, source: string, hidden: boolean): SessionSourceSettings {
  const key = normalizedSource(source)
  if (!key) return settings
  const rest = settings.hiddenSources.filter((item) => item !== key)
  return { hiddenSources: hidden ? [...rest, key].sort() : rest }
}

/** Whether a row shows under these settings. A row without a source always shows. */
export function showsSource(settings: SessionSourceSettings, source: string | null | undefined): boolean {
  const key = normalizedSource(source)
  return key === undefined || !settings.hiddenSources.includes(key)
}

/** The sources Settings offers, by label (HermesKit's `AppModel.knownSources`). */
export function knownSources(): string[] {
  return [...listedSources].sort((a, b) => sourceLabel(a).localeCompare(sourceLabel(b)))
}

/** `Platform` in `gateway/config.py:217-242`, plus the local and automatic surfaces. */
const labels: Record<string, string> = {
  desktop: 'Desktop', tui: 'Terminal (TUI)', cli: 'Command line', acp: 'Editor (ACP)',
  cron: 'Scheduled (cron)', subagent: 'Subagent', api_server: 'API server',
  webhook: 'Webhook', msgraph_webhook: 'Microsoft Graph webhook', relay: 'Relay',
  local: 'Local', unknown: 'Unknown',
  telegram: 'Telegram', discord: 'Discord', whatsapp: 'WhatsApp',
  whatsapp_cloud: 'WhatsApp Cloud', slack: 'Slack', signal: 'Signal',
  mattermost: 'Mattermost', matrix: 'Matrix', email: 'Email', sms: 'SMS',
  bluebubbles: 'iMessage (BlueBubbles)', dingtalk: 'DingTalk', feishu: 'Feishu',
  wecom: 'WeCom', wecom_callback: 'WeCom (callback)', weixin: 'WeChat',
  qqbot: 'QQ', yuanbao: 'Yuanbao',
}

/** A readable name for a source; unknown ones (plugin platforms) as stored. */
export function sourceLabel(source: string): string {
  const key = normalizedSource(source) ?? source
  return labels[key] ?? key
}
