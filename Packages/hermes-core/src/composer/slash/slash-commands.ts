import type { JSONValue } from '../../protocol/jsonrpc.ts'

/** What a slash command is (HermesKit's `SlashCommand.Kind`). */
export type SlashCommandKind = 'builtIn' | 'quick' | 'plugin' | 'skill'

/** One slash command the composer can offer (HermesKit's `SlashCommand`). */
export interface SlashCommand {
  /** With the leading slash, e.g. `/compress`. */
  name: string
  description: string
  /** The catalog category (`Session`, `User commands`, …); `Skills` for skills. */
  category: string
  kind: SlashCommandKind
  /** `options` | `text` | `mixed` (`contracts/tools_commands.py:194-203`). */
  argumentMode?: string
  /** Why the command cannot run from this app, or `undefined` when it can. */
  unavailableReason?: string
}

/** Per-command metadata of `commands.catalog` (`CommandsCatalogResult.Meta`). */
interface CommandMeta {
  argumentMode?: string
  desktop?: string
  desktopSubcommands?: string[]
}

/** One row of `complete.slash` (`SlashCompletionItem`). */
export interface SlashCompletionItem {
  text: string
  display?: string
  meta?: string
  kind?: string
}

const firstToken = (value: string): string => /^\S*/.exec(value)![0]
const record = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined
const stringOf = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined
const strings = (value: unknown): string[] | undefined =>
  Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : undefined
const pairs = (value: unknown): string[][] =>
  Array.isArray(value) ? value.map((pair) => strings(pair) ?? []) : []

/**
 * Does the composer text run as a slash command rather than a prompt? Desktop's
 * `SLASH_COMMAND_RE` (`apps/shared/src/slash.ts:11`): `/name` followed by whitespace or
 * the end, so `/usr/bin` is a normal prompt.
 */
export function isSlashCommand(value: string): boolean {
  const trimmed = value.trim()
  if (!trimmed.startsWith('/')) return false
  return !firstToken(trimmed.slice(1)).includes('/')
}

/** The list only follows a slash at the start of a one-line draft; a slash inside the command token is a path. */
export function isSlashCompletionCandidate(value: string): boolean {
  if (!value.startsWith('/') || value.includes('\n')) return false
  return !firstToken(value).slice(1).includes('/')
}

/**
 * Splits `/Name  some args` into (`name`, `some args`): the name is lower-cased and loses
 * its leading slashes; the argument keeps interior whitespace (`parseSlashCommand`).
 */
export function parseSlashCommand(value: string): { name: string; argument: string } {
  const body = value.trim().replace(/^\/+/, '')
  const name = firstToken(body)
  return { name: name.toLowerCase(), argument: body.slice(name.length).trim() }
}

/**
 * Commands Desktop runs as client-side actions or pickers and never sends to the gateway
 * (`desktop-slash-commands.ts:189-325`), minus the ones `runSlash` runs itself. They need
 * UI and come back as a `clientAction` outcome.
 */
export const slashClientActions: ReadonlySet<string> = new Set([
  'new', 'reset', 'clear', 'branch', 'fork', 'yolo', 'reasoning', 'wake', 'handoff', 'profile', 'skin',
  'help', 'commands', 'browser', 'journey', 'learning', 'memory-graph', 'model', 'resume', 'sessions',
  'switch', 'pet', 'hatch', 'generate-pet',
])

/** Desktop's local `desktopSubcommands`, used until a catalog says otherwise: `/skills` only reviews staged writes. */
const localSubcommands: Record<string, string[]> = { '/skills': ['pending', 'approve', 'reject', 'diff', 'approval'] }

/**
 * Catalog `desktop` values meaning "not available in a GUI client"
 * (`desktop-slash-commands.ts:440-483`), with Desktop's `UNAVAILABLE_MESSAGE`.
 */
const unavailableMessages: Record<string, (name: string) => string> = {
  terminal: (name) => `${name} is only available in the terminal interface.`,
  messaging: (name) => `${name} is only used from messaging platforms.`,
  settings: (name) => `${name} is managed from the Hermes Desktop sidebar.`,
  advanced: (name) => `${name} is not shown in the slash palette. Use the relevant Hermes Desktop control or the terminal interface instead.`,
  'composer-voice': () => "Voice chat isn't available in this app yet: Hermes's gateway voice methods record on the server's own microphone.",
}

function unavailableReason(name: string, meta: CommandMeta | undefined): string | undefined {
  const message = meta?.desktop !== undefined ? unavailableMessages[meta.desktop] : undefined
  return message?.(name)
}

/** The commands available in a session (`commands.catalog`, HermesKit's `SlashCatalog`). */
export class SlashCatalog {
  /** Category order as the gateway sends it; skills last. */
  readonly commands: SlashCommand[]
  /** Discovery problems the gateway reported (e.g. skills unavailable). */
  readonly warning?: string
  /** Alias → canonical name, both with a slash. */
  private readonly canon = new Map<string, string>()
  /** Per-command metadata, hidden commands included. */
  private readonly meta = new Map<string, CommandMeta>()

  /**
   * Builds the list the way Desktop's popover does (`use-slash-completions.ts:173-215`):
   * the categorized registry, quick and plugin commands, then every skill from `pairs`
   * under "Skills". Commands the catalog marks `hidden` are left out.
   */
  constructor(result: JSONValue | undefined | null) {
    const row = record(result) ?? {}
    const metaTable = record(row.commands) ?? {}
    const metaOf = (entry: unknown): CommandMeta => {
      const value = record(entry) ?? {}
      const meta: CommandMeta = {}
      const mode = stringOf(value.argument_mode)
      const desktop = stringOf(value.desktop)
      const subcommands = strings(value.desktop_subcommands)
      if (mode !== undefined) meta.argumentMode = mode
      if (desktop !== undefined) meta.desktop = desktop
      if (subcommands !== undefined) meta.desktopSubcommands = subcommands
      return meta
    }
    const skillNames = new Set(Object.keys(record(row.skills) ?? {}))
    const seen = new Set<string>()
    const commands: SlashCommand[] = []
    for (const categoryValue of Array.isArray(row.categories) ? row.categories : []) {
      const category = record(categoryValue)
      const categoryName = stringOf(category?.name)
      if (!category || categoryName === undefined) continue
      for (const pair of pairs(category.pairs)) {
        const name = pair[0]
        if (!name || seen.has(name)) continue
        seen.add(name)
        const meta = metaTable[name] !== undefined ? metaOf(metaTable[name]) : undefined
        if (meta?.desktop === 'hidden') continue
        const kind: SlashCommandKind = categoryName === 'User commands' ? 'quick'
          : categoryName === 'Plugin commands' ? 'plugin'
            : skillNames.has(name) ? 'skill' : 'builtIn'
        // Partly available when some subcommands are allowed (e.g. `/skills pending`).
        const reason = (meta?.desktopSubcommands ?? []).length === 0 ? unavailableReason(name, meta) : undefined
        const command: SlashCommand = { name, description: pair[1] ?? '', category: categoryName, kind }
        if (meta?.argumentMode !== undefined) command.argumentMode = meta.argumentMode
        if (reason !== undefined) command.unavailableReason = reason
        commands.push(command)
      }
    }
    // Skills ride `pairs` only (`methods_tools.py:489-500`).
    for (const pair of pairs(row.pairs)) {
      const name = pair[0]
      if (!name || !skillNames.has(name) || seen.has(name)) continue
      seen.add(name)
      commands.push({ name, description: pair[1] ?? '', category: 'Skills', kind: 'skill' })
    }
    this.commands = commands
    const warning = stringOf(row.warning)
    if (warning) this.warning = warning
    for (const [alias, canonical] of Object.entries(record(row.canon) ?? {})) {
      if (typeof canonical === 'string') this.canon.set(alias.toLowerCase(), canonical.toLowerCase())
    }
    for (const [name, entry] of Object.entries(metaTable)) this.meta.set(name.toLowerCase(), metaOf(entry))
  }

  /** The canonical `/name` for a typed name or alias. */
  canonicalName(name: string): string {
    const key = name.startsWith('/') ? name.toLowerCase() : '/' + name.toLowerCase()
    return this.canon.get(key) ?? key
  }

  /** A listed command by name or alias. */
  command(name: string): SlashCommand | undefined {
    const key = this.canonicalName(name)
    return this.commands.find((command) => command.name.toLowerCase() === key)
  }

  /**
   * Why `/name argument` must not run from this app, or `undefined` when it may.
   * Desktop's exec gate (`desktop-slash-commands.ts:551-587,705-720`): a command the
   * catalog marks unavailable in a GUI runs only for an allowed subcommand, and a command
   * narrowed by `desktop_subcommands` needs an allowed first argument token.
   */
  refusal(name: string, argument: string): string | undefined {
    const canonical = this.canonicalName(name)
    const display = name.startsWith('/') ? name : '/' + name
    const entry = this.meta.get(canonical)
    const allowed = entry?.desktopSubcommands ?? localSubcommands[canonical]
    const first = (argument.split(/\s+/).find((part) => part !== '') ?? '').toLowerCase()
    const reason = unavailableReason(canonical, entry)
    if (reason !== undefined && !allowed?.some((sub) => sub.toLowerCase() === first)) return reason
    if (!allowed) return undefined
    if (allowed.length === 0) return `${display} is not available in this app — use the terminal for it.`
    if (first === '') return `${display} needs a subcommand here: ${allowed.join(', ')}.`
    if (!allowed.some((sub) => sub.toLowerCase() === first)) {
      return `${display} ${first} is not available in this app — use the terminal for it. Available here: ${allowed.join(', ')}.`
    }
    return undefined
  }

  /** The command's `argument_mode`, for an alias too. */
  argumentMode(name: string): string | undefined {
    return this.meta.get(this.canonicalName(name))?.argumentMode ?? this.command(name)?.argumentMode
  }

  /**
   * Whether the text past the command name still gets a list. Only `options` and `mixed`
   * commands keep it; prose after any other command gets no list and no `complete.slash`
   * request (`use-composer-trigger.ts:173-184`).
   */
  listsArguments(value: string): boolean {
    const token = firstToken(value)
    if (token.length >= value.length) return true
    const mode = this.argumentMode(token)
    return mode === 'options' || mode === 'mixed'
  }

  /** A free-text argument is being typed: Return then sends unless the user arrowed to a row. */
  isFreeTextArgument(value: string): boolean {
    const token = firstToken(value)
    if (token.length >= value.length) return false
    const mode = this.argumentMode(token)
    return mode === 'text' || mode === 'mixed'
  }

  /**
   * Offered while browsing (`isDesktopSlashSuggestionWithOptions`): runnable from a GUI,
   * not narrowed to no subcommands, and not an alias.
   */
  isBrowsable(command: SlashCommand): boolean {
    const key = command.name.toLowerCase()
    return command.unavailableReason === undefined && this.meta.get(key)?.desktopSubcommands?.length !== 0 &&
      this.canonicalName(key) === key
  }

  /** Local `/help` output: the commands the list offers, in the catalog's order. */
  get helpText(): string {
    const lines = ['Available commands:']
    let category: string | undefined
    for (const command of this.commands) {
      if (!this.isBrowsable(command)) continue
      if (command.category !== category) {
        category = command.category
        lines.push(`\n${command.category}`)
      }
      lines.push(`${command.name} — ${command.description}`)
    }
    return lines.join('\n')
  }

  /**
   * The list for a draft. Bare `/` keeps the registry sections. A query follows the
   * server's ranking, keeping browsable commands, an alias only when typed exactly, and
   * arguments the `desktop_subcommands` gate allows; rows group as Desktop's, by the
   * item's `kind`: "Commands", then "Skills" (`use-slash-completions.ts:239-287`).
   */
  suggestions(value: string, completions?: SlashCompletions): SlashSuggestion[] {
    if (!isSlashCompletionCandidate(value)) return []
    if (value === '/') {
      return this.commands.filter((command) => this.isBrowsable(command)).map((command) => ({
        item: { text: command.name, display: command.name, meta: command.description },
        category: command.category,
        text: command.name,
      }))
    }
    if (!completions) return []
    if (completions.replaceFrom > 1) {
      return this.allowedArguments(completions.items, value).map((item) => ({
        item, category: 'Options', text: completions.applying(item),
      }))
    }
    const typed = value.toLowerCase()
    const rows = completions.items.flatMap((item): SlashSuggestion[] => {
      const name = item.text.toLowerCase()
      const isAlias = this.canonicalName(name) !== name
      const listed = this.command(name)
      if (listed) {
        if (!(isAlias ? name === typed && listed.unavailableReason === undefined : this.isBrowsable(listed))) return []
      } else {
        // Not in the catalog's list: a skill bundle, a gateway extra (`/details`), a plugin's
        // command. A registry command the catalog marks hidden or unavailable stays out.
        const entry = this.meta.get(this.canonicalName(name))
        if (entry?.desktop === 'hidden' || unavailableReason(name, entry) !== undefined || (isAlias && name !== typed)) return []
      }
      // `kind` from the backend; an older one sends none and the catalog decides.
      const isSkill = item.kind !== undefined ? item.kind === 'skill' : listed ? listed.kind === 'skill' : true
      return [{ item, category: isSkill ? 'Skills' : 'Commands', text: item.text }]
    })
    return [...rows.filter((row) => row.category === 'Commands'), ...rows.filter((row) => row.category === 'Skills')]
  }

  /** Argument rows the exec gate would not refuse (`desktop-slash-commands.ts:595-636`). */
  private allowedArguments(items: SlashCompletionItem[], value: string): SlashCompletionItem[] {
    const canonical = this.canonicalName(firstToken(value))
    const allowed = (this.meta.get(canonical)?.desktopSubcommands ?? localSubcommands[canonical])?.map((sub) => sub.toLowerCase())
    if (!allowed) return items
    const argument = value.slice(firstToken(value).length).replace(/^\s+/, '')
    const end = argument.search(/\s/)
    if (end >= 0) {
      // Past an allowed subcommand, the backend owns its value completions.
      return allowed.includes(argument.slice(0, end).toLowerCase()) ? items : []
    }
    return items.filter((item) => allowed.includes((item.text.split(/\s+/).find((part) => part !== '') ?? '').toLowerCase()))
  }
}

/** Completions for a typed `/` prefix (`complete.slash`, HermesKit's `SlashCompletions`). */
export class SlashCompletions {
  readonly items: SlashCompletionItem[]
  /** The column an accepted item replaces from. */
  readonly replaceFrom: number

  constructor(result: JSONValue | undefined | null, readonly text: string) {
    const row = record(result) ?? {}
    const replaceFrom = typeof row.replace_from === 'number' ? row.replace_from : 1
    const items = (Array.isArray(row.items) ? row.items : []).flatMap((entry): SlashCompletionItem[] => {
      const value = record(entry)
      const itemText = stringOf(value?.text)
      if (!value || itemText === undefined) return []
      const item: SlashCompletionItem = { text: itemText }
      const display = stringOf(value.display)
      const meta = stringOf(value.meta)
      const kind = stringOf(value.kind)
      if (display !== undefined) item.display = display
      if (meta !== undefined) item.meta = meta
      if (kind !== undefined) item.kind = kind
      return [item]
    })
    // The command stage replaces from column 1, after the slash: the gateway's items are
    // the bare name (`compress`, `compress ` on an exact match), its own extras keep the
    // slash. Desktop makes both `/name` (`commandText`, `use-slash-completions.ts:52-54`).
    this.items = replaceFrom > 1 ? items : items.map(commandItem)
    this.replaceFrom = replaceFrom
  }

  /**
   * The composer text after accepting `item`. Argument-stage items carry only the
   * argument stub and keep the command in front of it; command-stage items are the whole
   * `/command`.
   */
  applying(item: SlashCompletionItem): string {
    if (this.replaceFrom <= 1) return item.text
    return this.text.slice(0, this.replaceFrom) + item.text
  }
}

/** A command-stage item as `/name`: one leading slash, no surrounding whitespace. */
function commandItem(item: SlashCompletionItem): SlashCompletionItem {
  const name = item.text.trim().replace(/^\/+/, '')
  const command: SlashCompletionItem = { ...item, text: '/' + name }
  if (!command.display) command.display = command.text
  return command
}

/** A row the composer's list presents (HermesKit's `SlashSuggestion`). */
export interface SlashSuggestion {
  item: SlashCompletionItem
  category: string
  /** The composer text once this row is accepted. */
  text: string
}

/**
 * Which row Return takes when the user has not pressed Tab (`implicitSlashAcceptIndex`,
 * `composer-utils.ts:128-163`): a row the user arrowed to; else a row that is exactly the
 * typed text; else the highlight if it extends the typed text; else the only row that
 * does. `undefined`: none, so Return sends.
 */
export function implicitAcceptIndex(draft: string, texts: readonly string[], active: number, explicit: boolean): number | undefined {
  if (explicit && active >= 0 && active < texts.length) return active
  const token = (value: string): string => (value.startsWith('/') ? value.slice(1) : value).replace(/\s+$/, '').toLowerCase()
  const typed = token(draft)
  if (typed === '') return undefined
  const tokens = texts.map(token)
  const exact = tokens.indexOf(typed)
  if (exact >= 0) return exact
  if (active >= 0 && active < tokens.length && tokens[active]!.startsWith(typed)) return active
  const hits = tokens.flatMap((value, index) => value.startsWith(typed) ? [index] : [])
  return hits.length === 1 ? hits[0] : undefined
}

/** One row of the list, with everything the view draws for it (HermesKit's `SlashRow`). */
export interface SlashRow {
  /** Unique within its list: the row's text, plus `#n` for the nth repeat of a text. */
  id: string
  suggestion: SlashSuggestion
  /** The category header shown above this row (the first row of its category). */
  header?: string
  isSelected: boolean
}

export function slashRows(suggestions: readonly SlashSuggestion[], selection: number): SlashRow[] {
  const used = new Set<string>()
  return suggestions.map((suggestion, index) => {
    let id = suggestion.text
    let copy = 1
    while (used.has(id)) {
      copy += 1
      id = `${suggestion.text}#${copy}`
    }
    used.add(id)
    const row: SlashRow = { id, suggestion, isSelected: index === selection }
    if (index === 0 || suggestions[index - 1]!.category !== suggestion.category) row.header = suggestion.category
    return row
  })
}
