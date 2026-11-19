import type { LinkState } from '@talaria/hermes-core'

/** A server's status line and dot, as the Mac's `ConnectionState.statusText` / `statusColor`. */
export function linkStatus(link: LinkState): { text: string; tone: 'success' | 'caution' | 'neutral' | 'critical' } {
  switch (link.phase) {
    case 'disconnected': return { text: 'Disconnected', tone: 'neutral' }
    case 'connecting': return { text: 'Connecting…', tone: 'caution' }
    case 'connected': return { text: 'Connected', tone: 'success' }
    case 'reconnecting': return { text: `Reconnecting (attempt ${link.attempt})…`, tone: 'caution' }
    case 'failed': return { text: link.message, tone: 'critical' }
  }
}
