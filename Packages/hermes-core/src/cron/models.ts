/**
 * The models a cron job can pin, from a `model.options` answer
 * (`ModelOptionsResult`, `hermes_cli/inventory.py:74-165`): providers that offer at least
 * one model, in the server's order (HermesKit's `ModelCatalog`, the subset the job editor
 * uses; the composer's picker has its own).
 */
export interface CronModelProvider {
  slug: string
  name: string
  models: string[]
  /** False for a provider without credentials; the editor leaves those out. */
  authenticated?: boolean
}

export interface CronModelCatalog {
  providers: CronModelProvider[]
}

export function parseCronModelCatalog(value: unknown): CronModelCatalog {
  const rows = value && typeof value === 'object' ? (value as { providers?: unknown }).providers : undefined
  const providers: CronModelProvider[] = []
  for (const row of Array.isArray(rows) ? rows : []) {
    if (!row || typeof row !== 'object') continue
    const { slug, name, models, authenticated } = row as Record<string, unknown>
    if (typeof slug !== 'string' || !Array.isArray(models)) continue
    const ids = models.filter((model): model is string => typeof model === 'string')
    if (!ids.length) continue
    const provider: CronModelProvider = { slug, name: typeof name === 'string' ? name : slug, models: ids }
    if (typeof authenticated === 'boolean') provider.authenticated = authenticated
    providers.push(provider)
  }
  return { providers }
}

/** Whether the catalog offers `model` under `provider`. */
export function catalogOffers(catalog: CronModelCatalog | undefined, provider: string, model: string): boolean {
  return !!catalog?.providers.some((row) => row.slug === provider && row.models.includes(model))
}
