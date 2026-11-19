/**
 * A ready-made job with a few blanks to fill, from `GET /api/cron/blueprints?profile=`
 * (`hermes_cli/web_routers/cron.py:891-900`, `cron/blueprint_catalog.py`). Filling it in
 * creates a real job (`POST /api/cron/blueprints/instantiate`). Desktop offers them under
 * "Start from" in its New Cron Job dialog (`apps/desktop/src/app/cron/index.tsx:1409-1428`).
 * HermesKit's `CronBlueprint`.
 */
export type CronBlueprintFieldKind = 'text' | 'time' | 'weekdays' | 'enum'

export interface CronBlueprintField {
  name: string
  kind: CronBlueprintFieldKind
  label: string
  defaultValue?: string
  options: string[]
  isOptional: boolean
  help: string
}

export interface CronBlueprint {
  key: string
  title: string
  description: string
  fields: CronBlueprintField[]
  /** The plugin that registered it, for a plugin's blueprint. */
  plugin?: string
}

const kinds: readonly CronBlueprintFieldKind[] = ['text', 'time', 'weekdays', 'enum']

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined
}

function text(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

export function parseBlueprintField(value: unknown): CronBlueprintField | undefined {
  const json = record(value)
  const name = text(json?.name)
  if (!json || name === undefined) return undefined
  const type = text(json.type)
  const field: CronBlueprintField = {
    name,
    // An unknown kind is filled in as text, as Desktop's control falls back to.
    kind: kinds.includes(type as CronBlueprintFieldKind) ? type as CronBlueprintFieldKind : 'text',
    label: text(json.label) ?? name,
    options: Array.isArray(json.options) && json.options.every((item) => typeof item === 'string') ? json.options as string[] : [],
    isOptional: typeof json.optional === 'boolean' ? json.optional : false,
    help: text(json.help) ?? '',
  }
  const seeded = text(json.default)
  if (seeded !== undefined) field.defaultValue = seeded
  return field
}

export function parseBlueprint(value: unknown): CronBlueprint | undefined {
  const json = record(value)
  const key = text(json?.key)
  if (!json || key === undefined) return undefined
  const blueprint: CronBlueprint = {
    key,
    title: text(json.title) ?? key,
    description: text(json.description) ?? '',
    fields: Array.isArray(json.fields)
      ? json.fields.map(parseBlueprintField).filter((field): field is CronBlueprintField => field !== undefined)
      : [],
  }
  const plugin = text(json.plugin)
  if (plugin !== undefined) blueprint.plugin = plugin
  return blueprint
}

/** The deliver blank: offered as the job editor's delivery toggles, not its listed options. */
export function isDeliverField(field: CronBlueprintField): boolean {
  return field.name === 'deliver'
}

/**
 * Each blank's default. The deliver blank's `origin` (the chat a gateway job came from)
 * means nothing to an app, so it starts on `local` (`initialBlueprintValues`,
 * `apps/desktop/src/app/cron/blueprints.tsx:22-31`).
 */
export function blueprintInitialValues(blueprint: CronBlueprint): Record<string, string> {
  const values: Record<string, string> = {}
  for (const field of blueprint.fields) {
    const seeded = field.defaultValue ?? ''
    values[field.name] = isDeliverField(field) && (seeded === '' || seeded === 'origin') ? 'local' : seeded
  }
  return values
}

/** A blank's options, with its current value first when it's none of them. */
export function blueprintFieldOptions(field: CronBlueprintField, current: string): string[] {
  return field.options.includes(current) || current === '' ? field.options : [current, ...field.options]
}
