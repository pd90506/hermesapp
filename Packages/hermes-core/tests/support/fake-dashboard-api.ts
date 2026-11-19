import { DashboardRequestError, type DashboardAPI, type DashboardCallOptions, type GatewayAccess, type JSONValue } from '../../src/index.ts'

export interface RecordedCall {
  method: string
  path: string
  query: Record<string, string>
  body?: JSONValue
}

type Answer = JSONValue | Error

/** A dashboard answering `"METHOD path"` from a script, recording every call (HermesKit's `FakeDashboardAPI`). */
export class FakeDashboardAPI implements DashboardAPI {
  readonly calls: RecordedCall[] = []
  private readonly answers = new Map<string, Answer[]>()

  constructor(answers: Record<string, JSONValue> = {}) {
    for (const [key, value] of Object.entries(answers)) this.answers.set(key, [value])
  }

  /** Queues answers for a call; the last one repeats. */
  on(call: string, ...answers: Answer[]): void {
    this.answers.set(call, answers)
  }

  callsOf(method: string): RecordedCall[] {
    return this.calls.filter((call) => call.method === method)
  }

  async send(method: string, path: string, options: DashboardCallOptions = {}): Promise<JSONValue> {
    const call: RecordedCall = { method, path, query: Object.fromEntries(options.query ?? []) }
    if (options.body !== undefined) call.body = options.body
    this.calls.push(call)
    const queue = this.answers.get(`${method} ${path}`)
    if (!queue || queue.length === 0) throw new DashboardRequestError(404, `unscripted ${method} ${path}`)
    const next = queue.length > 1 ? queue.shift()! : queue[0]!
    if (next instanceof Error) throw next
    return next
  }
}

/** A `GatewayAccess` over a fake dashboard and a scripted gateway. */
export function access(api: DashboardAPI | undefined,
  gateway: (method: string, params: any) => unknown = () => { throw new Error('no gateway') }) {
  const gatewayCalls: Array<{ method: string; params: any }> = []
  const result: GatewayAccess & { gatewayCalls: typeof gatewayCalls } = {
    dashboardAPI: api,
    gatewayCalls,
    async call(method, params) {
      gatewayCalls.push({ method, params })
      return gateway(method, params) as JSONValue
    },
  }
  return result
}

/** Waits until `check` holds (HermesKit's `eventually`). */
export async function eventually(check: () => boolean, timeoutMs = 2000): Promise<void> {
  const start = Date.now()
  while (!check()) {
    if (Date.now() - start > timeoutMs) throw new Error('timed out')
    await new Promise<void>((resolve) => setTimeout(resolve, 5))
  }
}
