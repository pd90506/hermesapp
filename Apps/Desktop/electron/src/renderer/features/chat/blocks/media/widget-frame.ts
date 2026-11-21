/**
 * The page a `::preview` widget runs in, and the messages it may send back. Adapted from the
 * official Hermes Desktop's `inline-preview-directive.tsx` (hermes-agent, MIT, see
 * THIRD_PARTY_NOTICES.md): the same theme prelude names, the same size report and
 * `hermes.send` script, the same limits. Everything a frame posts is untrusted, so only a
 * message with this mount's token counts.
 */

export const widgetMinHeight = 120
export const widgetMaxHeight = 1200
export const widgetDefaultHeight = 280
/** The frame spans the reply's column up to this (Desktop's `MAX_FRAME_WIDTH`). */
export const widgetMaxWidth = 960
/** Sub-pixel churn ignored, so a page sized by `vh` cannot oscillate. */
export const widgetResizeTolerance = 4

const sizeMessage = 'hermes-inline-preview-size'
const intentMessage = 'hermes-inline-preview-intent'
const intentAckMessage = 'hermes-inline-preview-intent-ack'

/** A widget's prompt is a sentence, not a payload: a longer one is refused, never cut. */
export const maxIntentLength = 500
/** One prompt a second per frame; a faster one is refused with `retryAfterMs`. */
export const intentThrottleMs = 1000
const intentAckTimeoutMs = 5000

export type IntentError = 'invalid' | 'too_long' | 'throttled' | 'undelivered'
export type IntentAck = { ok: true } | { ok: false; error: IntentError; maxLength?: number; retryAfterMs?: number }
export type IntentDecision =
  | { kind: 'accept'; id: number | null; prompt: string }
  | { kind: 'reject'; id: number | null; ack: Extract<IntentAck, { ok: false }> }

/** `height="…"`: the starting height only, inside the band. */
export function initialWidgetHeight(raw: string | undefined): number | undefined {
  if (!raw) return undefined
  const parsed = Number(raw)
  if (!Number.isInteger(parsed)) return undefined
  return Math.min(widgetMaxHeight, Math.max(widgetMinHeight, parsed))
}

/** A size report from the frame with this token, clamped to the band; otherwise undefined. */
export function reportedHeight(data: unknown, token: string): number | undefined {
  if (typeof data !== 'object' || data === null) return undefined
  const message = data as { type?: unknown; token?: unknown; height?: unknown }
  if (message.type !== sizeMessage || message.token !== token || typeof message.height !== 'number') return undefined
  if (!Number.isFinite(message.height) || message.height <= 0) return undefined
  return Math.min(widgetMaxHeight, Math.max(widgetMinHeight, Math.round(message.height)))
}

/** A prompt from the frame with this token: accepted (trimmed) or refused with a reason; otherwise null. */
export function evaluateIntent(data: unknown, token: string, now: number, lastAcceptedAt: number): IntentDecision | null {
  if (typeof data !== 'object' || data === null) return null
  const message = data as { type?: unknown; token?: unknown; id?: unknown; prompt?: unknown }
  if (message.type !== intentMessage || message.token !== token) return null
  const id = typeof message.id === 'number' && Number.isSafeInteger(message.id) ? message.id : null
  const prompt = typeof message.prompt === 'string' ? message.prompt.trim() : ''
  if (prompt === '') return { kind: 'reject', id, ack: { ok: false, error: 'invalid' } }
  if (prompt.length > maxIntentLength) return { kind: 'reject', id, ack: { ok: false, error: 'too_long', maxLength: maxIntentLength } }
  const elapsed = now - lastAcceptedAt
  if (lastAcceptedAt > 0 && elapsed < intentThrottleMs) {
    return { kind: 'reject', id, ack: { ok: false, error: 'throttled', retryAfterMs: intentThrottleMs - elapsed } }
  }
  return { kind: 'accept', id, prompt }
}

export function intentAck(token: string, id: number, ack: IntentAck) {
  return { type: intentAckMessage, token, id, ack }
}

/** The app's colours under the names Hermes teaches the model (`var(--foreground)` and the rest). */
const themeTokens: Record<string, string> = {
  '--foreground': '--text',
  '--muted-foreground': '--text-tertiary',
  '--accent': '--accent',
  '--border': '--divider',
  '--card': '--surface-card',
}

export interface WidgetTheme {
  vars: Record<string, string>
  font: string
  colorScheme: 'light' | 'dark'
}

/** Reads the live theme from the document in one go, so its parts never disagree. */
export function currentWidgetTheme(element: Element = document.documentElement): WidgetTheme {
  const style = getComputedStyle(element)
  const vars: Record<string, string> = {}
  for (const [alias, source] of Object.entries(themeTokens)) {
    const value = style.getPropertyValue(source).trim()
    if (value) vars[alias] = value
  }
  const font = getComputedStyle(document.body).fontFamily
  const dark = typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches
  return { vars, font, colorScheme: dark ? 'dark' : 'light' }
}

/** Injected first, so the page's own styles win: the colours, the scheme, the font, no margins, a clear canvas. */
export function themePrelude(theme: WidgetTheme): string {
  const tokens = Object.entries(theme.vars).map(([name, value]) => `${name}:${value}`).join(';')
  const font = theme.font ? `font-family:${theme.font};` : ''
  return `<style>:root{color-scheme:${theme.colorScheme};${tokens}}` +
    `html,body{margin:0;padding:0;background:transparent;color:var(--foreground,inherit);${font}}</style>`
}

/** Reports the content's height; postMessage is the frame's only door. */
function measurementScript(token: string): string {
  return '<script>(function(){var t=' + JSON.stringify(token) +
    ';var lastH=0;function post(){var d=document.documentElement;var b=document.body;' +
    'var h=Math.max(d?d.scrollHeight:0,b?b.scrollHeight:0);' +
    'if(Math.abs(h-lastH)>1){lastH=h;parent.postMessage({type:' + JSON.stringify(sizeMessage) +
    ',token:t,height:h},"*")}}' +
    'if(typeof ResizeObserver==="function"){var ro=new ResizeObserver(post);' +
    'ro.observe(document.documentElement);if(document.body)ro.observe(document.body)}' +
    'addEventListener("load",post);post()})()</script>'
}

/** `hermes.send(prompt)` and `data-hermes-send="…"`: a prompt, answered by an ack. */
function intentScript(token: string): string {
  return '<script>(function(){var t=' + JSON.stringify(token) + ';var n=0,w={};' +
    'addEventListener("message",function(e){var d=e.data;' +
    'if(e.source!==parent||!d||d.type!==' + JSON.stringify(intentAckMessage) +
    '||d.token!==t||!w[d.id])return;var r=w[d.id];delete w[d.id];r(d.ack)});' +
    'function send(p){if(typeof p!=="string"||!p.trim())return Promise.resolve({ok:false,error:"invalid"});' +
    'var id=++n;return new Promise(function(res){var done=function(a){clearTimeout(k);res(a)};' +
    'var k=setTimeout(function(){if(w[id]){delete w[id];res({ok:false,error:"undelivered"})}},' +
    String(intentAckTimeoutMs) + ');w[id]=done;parent.postMessage({type:' + JSON.stringify(intentMessage) +
    ',token:t,id:id,prompt:p},"*")})}' +
    'window.hermes={send:send,maxLength:' + String(maxIntentLength) + '};' +
    'addEventListener("click",function(e){var el=e.target&&e.target.closest?' +
    'e.target.closest("[data-hermes-send]"):null;' +
    'if(el)send(el.getAttribute("data-hermes-send")||"")},true)})()</script>'
}

/**
 * The page as served: the prelude first (after a `<!doctype>`, which must lead or the page
 * renders in quirks mode), the scripts before `</body>` (or at the end).
 */
export function widgetDocument(html: string, token: string, theme: WidgetTheme): string {
  const scripts = measurementScript(token) + intentScript(token)
  const bodyClose = /<\/body\s*>/i.exec(html)
  const framed = bodyClose ? html.slice(0, bodyClose.index) + scripts + html.slice(bodyClose.index) : html + scripts
  const doctype = /^\s*<!doctype[^>]*>/i.exec(framed)
  const lead = doctype ? doctype[0] : '<!doctype html>'
  return lead + '<meta charset="utf-8">' + themePrelude(theme) + framed.slice(doctype ? doctype[0].length : 0)
}
