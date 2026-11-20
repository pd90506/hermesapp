import type { JSONValue } from '../../protocol/jsonrpc.ts'

/** A model's switches as the catalog lists them (`ModelCapabilities`). */
export interface ModelCapabilities {
  fast?: boolean
  reasoning?: boolean
  canDisableReasoning?: boolean
}

/** One provider row of `model.options` (`ModelOptionProvider`). */
export interface ModelOptionProvider {
  /** Sent as `--provider`. */
  slug: string
  name: string
  models: string[]
  isCurrent?: boolean
  authenticated?: boolean
  warning?: string
  /** Other names `session.info` may report this provider by (a saved `custom:<key>`). */
  aliases?: string[]
  capabilities?: Record<string, ModelCapabilities>
}

/** One pickable model: a model id under the provider that serves it (`ModelChoice`). */
export interface ModelChoice {
  provider: string
  model: string
}

export function modelChoiceID(choice: ModelChoice): string {
  return `${choice.provider}\u0000${choice.model}`
}

const record = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined
const text = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined
const flag = (value: unknown): boolean | undefined => typeof value === 'boolean' ? value : undefined

function capabilities(value: unknown): ModelCapabilities | undefined {
  const row = record(value)
  if (!row) return undefined
  const caps: ModelCapabilities = {}
  const fast = flag(row.fast)
  const reasoning = flag(row.reasoning)
  const canDisable = flag(row.can_disable_reasoning)
  if (fast !== undefined) caps.fast = fast
  if (reasoning !== undefined) caps.reasoning = reasoning
  if (canDisable !== undefined) caps.canDisableReasoning = canDisable
  return caps
}

/** A provider row; `undefined` without a slug. Like HermesKit's decoder, a bad `capabilities` is dropped, not fatal. */
function provider(value: unknown): ModelOptionProvider | undefined {
  const row = record(value)
  const slug = text(row?.slug)
  if (!row || slug === undefined) return undefined
  const result: ModelOptionProvider = {
    slug,
    name: text(row.name) ?? slug,
    models: Array.isArray(row.models) ? row.models.filter((model): model is string => typeof model === 'string') : [],
  }
  const isCurrent = flag(row.is_current)
  const authenticated = flag(row.authenticated)
  const warning = text(row.warning)
  if (isCurrent !== undefined) result.isCurrent = isCurrent
  if (authenticated !== undefined) result.authenticated = authenticated
  if (warning !== undefined) result.warning = warning
  if (Array.isArray(row.aliases)) result.aliases = row.aliases.filter((alias): alias is string => typeof alias === 'string')
  const caps = record(row.capabilities)
  if (caps) {
    const table: Record<string, ModelCapabilities> = {}
    for (const [model, entry] of Object.entries(caps)) {
      const parsed = capabilities(entry)
      if (parsed) table[model] = parsed
    }
    result.capabilities = table
  }
  return result
}

const collator = new Intl.Collator('en', { numeric: true, sensitivity: 'base' })
const byName = (a: string, b: string): number => collator.compare(a, b) || (a < b ? -1 : a > b ? 1 : 0)

/**
 * The model picker's data, built from a `model.options` answer (HermesKit's
 * `ModelCatalog`): providers that offer at least one model; a catalog with no models is
 * nothing to pick (`model-options.ts:131-133`). Sorted so the menu never reshuffles:
 * providers by name, as Desktop (`model-catalog-menu.tsx`, "the backend floats the current
 * provider first, which would reshuffle on every switch"), and their models by id, since
 * an endpoint's own model list can come back in a different order each time.
 */
export class ModelCatalog {
  readonly providers: readonly ModelOptionProvider[]
  /** The gateway's view of the current pair; the session's own `session.info` wins over it. */
  readonly model?: string
  readonly provider?: string

  constructor(result: JSONValue | ModelOptionProvider[] | null | undefined) {
    const row = record(result)
    const rows = Array.isArray(result) ? result : Array.isArray(row?.providers) ? row.providers : []
    this.providers = rows.map(provider)
      .filter((entry): entry is ModelOptionProvider => entry !== undefined && entry.models.length > 0)
      .map((entry) => ({ ...entry, models: [...entry.models].sort(byName) }))
      .sort((a, b) => byName(a.name, b.name))
    const model = text(row?.model)
    const current = text(row?.provider)
    if (model) this.model = model
    if (current) this.provider = current
  }

  get isEmpty(): boolean {
    return this.providers.length === 0
  }

  /** The catalog row's capabilities for a model; `undefined` when the catalog does not list it. */
  capabilities(model: string, provider?: string): ModelCapabilities | undefined {
    const matched = provider !== undefined ? this.providerRow(provider) : undefined
    for (const row of this.providers) {
      if (provider !== undefined && matched !== undefined && row !== matched) continue
      const caps = row.capabilities?.[model]
      if (caps) return caps
    }
    return undefined
  }

  /**
   * The row a reported provider names: by slug, display name or alias, as Desktop's
   * `catalogProviderMatches` (`lib/model-options.ts`); `session.info` may report a custom
   * endpoint by a name the catalog row only carries as an alias.
   */
  providerRow(current: string): ModelOptionProvider | undefined {
    const wanted = current.toLowerCase()
    return this.providers.find((row) => row.slug.toLowerCase() === wanted || row.name.toLowerCase() === wanted ||
      (row.aliases ?? []).some((alias) => alias.toLowerCase() === wanted))
  }

  /** The provider display name for a slug. */
  providerName(slug: string): string {
    return this.providers.find((row) => row.slug.toLowerCase() === slug.toLowerCase())?.name ?? slug
  }
}

/** The `config.set model` value that switches this session only (`ModelSwitch.sessionValue`). */
export function sessionModelValue(choice: ModelChoice): string {
  const provider = choice.provider.trim()
  let value = choice.model.trim()
  if (provider !== '') value += ` --provider ${provider}`
  return value + ' --session'
}

const variantTags: Array<[string, string]> = [
  ['-fast', 'Fast'], ['-flash', 'Flash'], ['-thinking', 'Thinking'], ['-preview', 'Preview'], ['-latest', 'Latest'],
]

const vendorCasing = new Map<string, string>([
  ['Deepseek', 'DeepSeek'], ['Glm', 'GLM'], ['Minimax', 'MiniMax'], ['Openai', 'OpenAI'], ['Ernie', 'ERNIE'],
  ['Mimo', 'MiMo'], ['Bge', 'BGE'], ['Vl', 'VL'], ['It', 'IT'], ['Fp8', 'FP8'], ['Ai', 'AI'],
])

/**
 * Human model names for the composer (HermesKit's `ModelLabel.displayName`, after
 * Desktop's `modelDisplayParts` in `lib/model-status-label.ts`): drops a vendor prefix
 * and a date pin, dots Anthropic versions and keeps variants (`-fast`, `[1m]`) visible so
 * distinct ids never read the same.
 */
export function modelDisplayName(model: string): string {
  const trimmed = model.trim()
  if (trimmed === '') return 'No model'
  let base = trimmed.split('/').filter((part) => part !== '').at(-1) ?? trimmed
  const tags: string[] = []
  for (const [suffix, tag] of variantTags) {
    if (base.toLowerCase().endsWith(suffix)) {
      base = base.slice(0, -suffix.length)
      tags.push(tag)
      break
    }
  }
  const context = /\[(\d+[mMkK])\]$/.exec(base)
  if (context) {
    tags.push(context[1]!.toUpperCase())
    base = base.slice(0, context.index)
  }
  base = base.replace(/-\d{8}$/, '')
  const name = prettify(base)
  const full = name === '' ? trimmed : name
  return tags.length === 0 ? full : `${full} · ${tags.join(' ')}`
}

function prettify(base: string): string {
  const lower = base.toLowerCase()
  if (lower.startsWith('claude-')) {
    // `opus-5-5` → "Opus 5.5": hyphens between digits are version dots.
    const rest = base.slice('claude-'.length).replace(/(\d)-(?=\d)/g, '$1.').replace(/-/g, ' ')
    return vendorCase(titleCase(rest))
  }
  if (lower.startsWith('gpt-')) return 'GPT-' + base.slice('gpt-'.length)
  return vendorCase(titleCase(base.replace(/-/g, ' ')))
}

/** Upper-cases the first letter of every word, like JavaScript's `\b\w`. */
function titleCase(value: string): string {
  let result = ''
  let atWordStart = true
  for (const character of value) {
    const isWord = /[\p{L}\p{N}_]/u.test(character)
    result += atWordStart && isWord ? character.toUpperCase() : character
    atWordStart = !isWord
  }
  return result.trim()
}

function vendorCase(value: string): string {
  return value.split(' ').map((word) => {
    // Parameter counts: "8b" → "8B", "A22b" → "A22B".
    if (/^[aA]?\d+(\.\d+)?[bB]$/.test(word)) return word.toUpperCase()
    return vendorCasing.get(word) ?? word
  }).join(' ')
}
