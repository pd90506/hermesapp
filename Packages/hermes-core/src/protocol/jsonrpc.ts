/**
 * JSON-RPC 2.0 framing as the Hermes TUI gateway uses it (HermesKit's `JSONRPC.swift`):
 * one text frame is one message; the gateway sends responses, `event` notifications and
 * requests of its own (approvals, clarify, ...).
 */
export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue }

export type RPCID = string | number

export interface RPCErrorBody {
  code: number
  message: string
  data?: JSONValue
}

export class RPCError extends Error {
  readonly code: number
  readonly data?: JSONValue
  constructor(body: RPCErrorBody) {
    super(body.message)
    this.code = body.code
    if (body.data !== undefined) this.data = body.data
  }

  static readonly parseError = -32700
  static readonly invalidRequest = -32600
  static readonly methodNotFound = -32601
  static readonly invalidParams = -32602
  static readonly internalError = -32603
}

export interface RPCRequest {
  jsonrpc: '2.0'
  id?: RPCID
  method: string
  params?: JSONValue
}

export interface RPCResponse {
  jsonrpc: '2.0'
  id: RPCID | null
  result?: JSONValue
  error?: RPCErrorBody
}

export type RPCMessage = { kind: 'request'; request: RPCRequest } | { kind: 'response'; response: RPCResponse }

/** Decodes one frame, or `undefined` for a frame that is not a JSON-RPC message. */
export function decodeMessage(text: string): RPCMessage | undefined {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return undefined
  const object = raw as Record<string, unknown>
  if (typeof object.method === 'string') {
    const request: RPCRequest = { jsonrpc: '2.0', method: object.method }
    if (typeof object.id === 'string' || typeof object.id === 'number') request.id = object.id
    if (object.params !== undefined) request.params = object.params as JSONValue
    return { kind: 'request', request }
  }
  if ('result' in object || 'error' in object) {
    const id = typeof object.id === 'string' || typeof object.id === 'number' ? object.id : null
    const response: RPCResponse = { jsonrpc: '2.0', id }
    const error = object.error as RPCErrorBody | undefined
    if (error && typeof error === 'object' && typeof error.code === 'number') {
      response.error = { code: error.code, message: String(error.message ?? ''), ...(error.data !== undefined ? { data: error.data } : {}) }
    } else {
      // `result: null` is a valid success.
      response.result = (object.result ?? null) as JSONValue
    }
    return { kind: 'response', response }
  }
  return undefined
}

export function encodeRequest(id: RPCID | undefined, method: string, params?: JSONValue): string {
  const message: RPCRequest = { jsonrpc: '2.0', method }
  if (id !== undefined) message.id = id
  if (params !== undefined) message.params = params
  return JSON.stringify(message)
}

export function encodeResponse(id: RPCID, outcome: { result: JSONValue } | { error: RPCErrorBody }): string {
  return JSON.stringify({ jsonrpc: '2.0', id, ...outcome })
}
