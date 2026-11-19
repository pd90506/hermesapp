/**
 * The address a Markdown link opens in the system's browser or mail app, or undefined
 * for one the app does not follow (a relative path, `file:`, `javascript:`, a
 * credential-bearing URL). The main process checks the same rule again before it
 * hands the address to the system.
 */
export function externalLinkTarget(href: string | undefined | null): string | undefined {
  const text = href?.trim()
  if (!text) return undefined
  let url: URL
  try {
    url = new URL(text)
  } catch {
    // A bare `www.` address, as GFM autolinks write it.
    if (!/^www\.[^\s/]/i.test(text)) return undefined
    try { url = new URL(`https://${text}`) } catch { return undefined }
  }
  if (url.protocol === 'mailto:') return url.href
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined
  if (url.username || url.password || !url.hostname) return undefined
  return url.href
}
