/**
 * The user-entered dashboard address, normalised as HermesKit's `GatewayEndpoint` and
 * Hermes Desktop (`apps/desktop/.../connection-config.ts`) do: a bare `host:port` gets
 * `http://`, `ws(s)` becomes `http(s)`, credentials, query and fragment are dropped, a
 * path prefix (reverse proxy) is kept and its trailing slashes removed.
 */
export class GatewayEndpoint {
  /** `http(s)://host[:port][/prefix]`, without a trailing slash. */
  readonly baseURL: string
  private readonly url: URL

  constructor(input: string) {
    let text = input.trim()
    if (!text.includes('://')) text = 'http://' + text
    const scheme = text.slice(0, text.indexOf('://')).toLowerCase()
    let mapped: string
    switch (scheme) {
      case 'http':
      case 'https':
        mapped = scheme
        break
      case 'ws':
        mapped = 'http'
        break
      case 'wss':
        mapped = 'https'
        break
      default:
        if (!/^[a-z][a-z0-9+.-]*$/.test(scheme)) throw new EndpointError('invalidURL', input)
        throw new EndpointError('unsupportedScheme', scheme)
    }
    let url: URL
    try {
      url = new URL(mapped + text.slice(scheme.length))
    } catch {
      throw new EndpointError('invalidURL', input)
    }
    if (!url.hostname) throw new EndpointError('invalidURL', input)
    url.username = ''
    url.password = ''
    url.search = ''
    url.hash = ''
    url.pathname = url.pathname.replace(/\/+$/, '')
    this.url = url
    this.baseURL = url.href.replace(/\/+$/, '')
  }

  get isSecure(): boolean {
    return this.url.protocol === 'https:'
  }

  /** An HTTP(S) URL for a dashboard path such as `/api/status`. */
  urlFor(path: string, query: ReadonlyArray<readonly [string, string]> = []): string {
    const url = new URL(this.baseURL)
    url.pathname = url.pathname.replace(/\/+$/, '') + (path.startsWith('/') ? path : '/' + path)
    for (const [name, value] of query) url.searchParams.append(name, value)
    return url.href
  }

  /** `ws(s)://host[/prefix]/api/ws?<query>`. */
  webSocketURL(query: ReadonlyArray<readonly [string, string]>): string {
    const url = new URL(this.urlFor('/api/ws', query))
    url.protocol = this.isSecure ? 'wss:' : 'ws:'
    return url.href
  }
}

export class EndpointError extends Error {
  constructor(readonly kind: 'invalidURL' | 'unsupportedScheme', readonly value: string) {
    super(kind === 'invalidURL' ? `Not a server address: ${value}` : `Unsupported scheme: ${value}`)
  }
}

/**
 * The name shown for a server without one (HermesKit's `ServerConfig.defaultName`): the
 * first label of a host name (`hermes` for `hermes.example.ts.net`), the whole host and
 * port for an IP address or `localhost`.
 */
export function defaultServerName(serverURL: string): string | undefined {
  let endpoint: GatewayEndpoint
  try {
    endpoint = new GatewayEndpoint(serverURL)
  } catch {
    return undefined
  }
  const url = new URL(endpoint.baseURL)
  const host = url.hostname
  if (!host) return undefined
  const bare = host.replace(/^\[|\]$/g, '')
  const isAddress = bare === 'localhost' || bare.includes(':') ||
    bare.split('.').every((part) => part.length > 0 && /^\d+$/.test(part))
  if (isAddress) {
    const shown = bare.includes(':') ? `[${bare}]` : bare
    return url.port ? `${shown}:${url.port}` : shown
  }
  return host.split('.')[0] || host
}
