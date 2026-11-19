import type { BridgeHttpRequest, BridgeHttpResponse } from '../shared/bridge.ts'

/**
 * HTTP to the dashboard from the main process, with Node's fetch: no browser `Origin`,
 * no CORS, as the Swift apps' requests. The dashboard's session lives in cookies
 * (`/auth/password-login` answers with Set-Cookie only), kept here in memory per host
 * as HermesKit's ephemeral URLSession keeps them, and sent back to the same host.
 */
export class DashboardHttp {
  /** host → cookie name → value. */
  private readonly cookies = new Map<string, Map<string, string>>()

  async send(request: BridgeHttpRequest): Promise<BridgeHttpResponse> {
    const url = new URL(request.url)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('Only http(s) requests')
    const headers: Record<string, string> = { ...request.headers }
    const jar = this.cookies.get(url.host)
    if (jar && jar.size > 0) headers.Cookie = [...jar].map(([name, value]) => `${name}=${value}`).join('; ')
    let response: Response
    try {
      response = await fetch(url, {
        method: request.method,
        headers,
        ...(request.body !== undefined ? { body: request.body } : {}),
        redirect: 'manual',
        signal: AbortSignal.timeout(request.timeoutMs ?? 15_000),
      })
    } catch (error) {
      // Node's fetch says only "fetch failed"; the reason (refused, no such host, TLS) is its cause.
      const cause = (error as { cause?: { code?: string; message?: string } }).cause
      const reason = cause?.code ?? cause?.message
      throw new Error(reason ? `${url.host}: ${reason}` : String(error instanceof Error ? error.message : error))
    }
    this.keep(url.host, response.headers.getSetCookie())
    return { status: response.status, body: await response.text() }
  }

  reset(): void {
    this.cookies.clear()
  }

  private keep(host: string, setCookies: string[]): void {
    if (setCookies.length === 0) return
    const jar = this.cookies.get(host) ?? new Map<string, string>()
    for (const line of setCookies) {
      const [pair = '', ...attributes] = line.split(';')
      const at = pair.indexOf('=')
      if (at <= 0) continue
      const name = pair.slice(0, at).trim()
      const value = pair.slice(at + 1).trim()
      const expired = attributes.some((attribute) => {
        const [key = '', setting = ''] = attribute.split('=').map((part) => part.trim())
        return (key.toLowerCase() === 'max-age' && Number(setting) <= 0) ||
          (key.toLowerCase() === 'expires' && Date.parse(setting) < Date.now())
      })
      if (expired || value === '') jar.delete(name)
      else jar.set(name, value)
    }
    this.cookies.set(host, jar)
  }
}
