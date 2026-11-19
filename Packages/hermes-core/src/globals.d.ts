// The few web-platform globals the core uses, which both a browser renderer and Node
// provide. Declared here instead of pulling in the DOM or Node typings, so code that
// needs either one does not type-check in this package.
declare function setTimeout(handler: () => void, ms?: number): unknown
declare function clearTimeout(id: unknown): void
declare function setInterval(handler: () => void, ms?: number): unknown
declare function clearInterval(id: unknown): void
declare function queueMicrotask(callback: () => void): void

declare class URLSearchParams {
  append(name: string, value: string): void
  get(name: string): string | null
}

declare class URL {
  constructor(url: string, base?: string)
  href: string
  protocol: string
  username: string
  password: string
  hostname: string
  port: string
  pathname: string
  search: string
  hash: string
  readonly searchParams: URLSearchParams
}

declare class TextEncoder {
  encode(input: string): Uint8Array
}

declare var crypto: { getRandomValues<T extends Uint8Array>(array: T): T }
