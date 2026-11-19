import { hasReplyText, isBlankReply, isQueuedPrompt, isSteer, type TranscriptItem } from '../items.ts'
import { elapsedText } from '../transcript.ts'
import { argString, firstURLString, isCardTool, toolArgs, ToolCallSummary, toolNameOf } from './tool-call-summary.ts'
import { toolCallView } from './tool-call-view.ts'

/**
 * Everything a turn did before its answer, in three layers, as the user asked
 * (2026-10-18, PR #59; HermesKit's `TurnWork`):
 * 1. one line, "Completed in 45s" once the turn is done, with the answer under it;
 * 2. opened, the turn's commentary and its groups of steps ("Ran commands");
 * 3. a group opened, its steps one line each ("Bash · git status", "Think · …"), each
 *    opening in place to the command and its output, or the whole reasoning.
 *
 * Calls Desktop draws as cards (a question for the user, delegated tasks) keep a row of
 * their own in the second layer.
 */
export interface TurnWork {
  id: string
  /** The rows the work holds, in order. The answer is not one of them, though its reasoning is a step here. */
  items: readonly TranscriptItem[]
  entries: readonly WorkEntry[]
  /** The turn is still working and nothing has come after the work. */
  isLive: boolean
  /** Unix ms: when the turn (or the part of it after a steer) began, the row before the work. */
  startedAt?: number
  /** Unix ms: the answer's row, else the work's last row with a time. A live row has none. */
  endedAt?: number
  /** The turn was stopped before it answered. */
  wasInterrupted: boolean
}

export type WorkEntry =
  /** Text the model wrote between its steps (its reasoning is a step). */
  | { kind: 'commentary'; id: string; item: TranscriptItem }
  | { kind: 'group'; id: string; group: StepGroup }
  /** A call drawn as its own card. */
  | { kind: 'card'; id: string; item: TranscriptItem }

/** Consecutive steps of a turn's work under one row, named after what its calls did. */
export interface StepGroup {
  id: string
  steps: readonly WorkStep[]
  /** The work is live and this is its last group. */
  isLive: boolean
}

/** One step of a turn's work: a row's reasoning, or a tool call. */
export type WorkStep =
  /** The row's reasoning; the row's text is not part of the step. */
  | { kind: 'think'; id: string; item: TranscriptItem }
  | { kind: 'tool'; id: string; item: TranscriptItem }

/** How long the work took, in seconds, when both ends are known. */
export function workDuration(work: TurnWork): number | undefined {
  if (work.startedAt === undefined || work.endedAt === undefined || work.endedAt < work.startedAt) return undefined
  return (work.endedAt - work.startedAt) / 1000
}

/** The settled line: "Completed in 45s", "Stopped after 1m 05s", or without a time when it is not known. */
export function settledTitle(seconds: number | undefined, interrupted: boolean): string {
  if (seconds === undefined) return interrupted ? 'Stopped' : 'Completed'
  return `${interrupted ? 'Stopped after' : 'Completed in'} ${elapsedText(0, seconds * 1000)}`
}

/** "Working… 12s", while the turn works. */
export function workingTitle(startMs: number, nowMs: number): string {
  return `Working… ${elapsedText(startMs, nowMs)}`
}

// MARK: Groups

export const StepGroups = {
  tools: (group: StepGroup): TranscriptItem[] => group.steps.flatMap((step) => (step.kind === 'tool' ? [step.item] : [])),
  /** "Ran commands, read files", "Analysis completed". */
  title: (group: StepGroup): string => ToolCallSummary.groupTitle(StepGroups.tools(group), group.isLive),
  /** The calls counted, as Desktop's run line reads: "Ran 5 commands, explored 3 files". */
  summary: (group: StepGroup): string => ToolCallSummary.run(StepGroups.tools(group), group.isLive),
  /** The tool whose icon the row shows: its first call's, or none for reasoning alone. */
  iconTool(group: StepGroup): string | undefined {
    const first = StepGroups.tools(group)[0]
    return first ? toolNameOf(first) : undefined
  },
  /** The step the group's line shows: its newest, while the turn works in it. */
  liveStep: (group: StepGroup): WorkStep | undefined => (group.isLive ? group.steps[group.steps.length - 1] : undefined),
} as const

// MARK: Steps

const kinds: Record<string, string> = {
  terminal: 'Bash', execute_code: 'Python', process_manage: 'Process',
  read_file: 'Read', list_files: 'List', search_files: 'Search',
  write_file: 'Write', edit_file: 'Edit', patch: 'Patch',
  web_search: 'Web search', web_extract: 'Fetch', vision_analyze: 'Vision',
  image_generate: 'Image', skill_view: 'Skill', skills_list: 'Skills',
  memory: 'Memory', todo: 'Todo', clarify: 'Ask', delegate_task: 'Delegate',
  cronjob: 'Cron', session_search_recall: 'Recall',
}

export const WorkSteps = {
  /** Still being written or run. */
  isLive: (step: WorkStep): boolean => (step.kind === 'think' ? step.item.isActive && !hasReplyText(step.item) : step.item.isActive),

  toolName: (step: WorkStep): string | undefined => (step.kind === 'tool' ? toolNameOf(step.item) : undefined),

  failed: (step: WorkStep): boolean => step.item.tool?.phase === 'failed',

  /** The step's kind as its line starts: "Think", "Bash", "Read". */
  kind(step: WorkStep): string {
    const name = WorkSteps.toolName(step)
    if (name === undefined) return 'Think'
    return kinds[name] ?? (name.startsWith('browser_') ? 'Browser' : name)
  },

  /** What the step was about, on one line: the reasoning's first line, the command, the path, query or address, else the call's title. */
  summary(step: WorkStep): string {
    if (step.kind === 'think') return firstLine(step.item.reasoning, true)
    const item = step.item
    const args = toolArgs(item)
    const name = toolNameOf(item)
    const context = item.tool?.context ?? item.detail
    let value: string | undefined
    if (name === 'terminal') value = argString(args, ['command']) ?? context
    else if (name === 'execute_code') value = argString(args, ['code']) ?? context
    else value = argString(args, ['path', 'file_path', 'file', 'filepath', 'query', 'search_term', 'pattern', 'url', 'name']) ?? firstURLString(args)
    return value !== undefined ? firstLine(value) : toolCallView(item).title
  },

  /** `terminal`'s working folder for this call (`workdir`), when it named one. */
  workdir(step: WorkStep): string | undefined {
    if (step.kind !== 'tool' || WorkSteps.toolName(step) !== 'terminal') return undefined
    return argString(toolArgs(step.item), ['workdir'])
  },

  /** What the step's Copy button takes: the whole command or code, the whole reasoning, else the call's output. */
  copyText(step: WorkStep): string {
    if (step.kind === 'think') return step.item.reasoning
    const view = toolCallView(step.item)
    if (view.terminalCommand) return view.terminalCommand
    const code = argString(toolArgs(step.item), ['code'])
    if (code !== undefined) return code
    return view.detail === '' ? view.title : view.detail
  },
} as const

/** The first line with text; with `plain`, without its Markdown marks (a heading's `#`, a bullet, a quote's `>`, bold stars). */
export function firstLine(text: string, plain = false): string {
  const line = text.split(/\r\n|\n|\r/).map((part) => part.replace(/^[^\S\n]+|[^\S\n]+$/g, '')).find((part) => part !== '')
  if (line === undefined) return ''
  if (!plain) return line
  return line.replace(/^(#{1,6}\s+|[-*+]\s+|>\s*)/, '').replaceAll('**', '').replaceAll('__', '')
}

/** The row without its reasoning, for where its reasoning is drawn as a step. */
export function withoutReasoning(item: TranscriptItem): TranscriptItem {
  return item.reasoning === '' ? item : { ...item, reasoning: '' }
}

// MARK: Grouping (HermesKit's `TranscriptGrouping`)

export type GroupedBlock =
  | { kind: 'item'; item: TranscriptItem }
  | { kind: 'work'; work: TurnWork }

/**
 * Splits the items into turns (a user row starts one; a steer joins the running turn)
 * and folds each turn's work before its answer into one block. A queued prompt waits
 * above the composer and is not listed.
 */
export function groupTurns(items: readonly TranscriptItem[], isRunning: boolean): GroupedBlock[] {
  const turns: TranscriptItem[][] = []
  for (const item of items) {
    if (isQueuedPrompt(item)) continue
    if (turns.length === 0 || (item.role === 'user' && !isSteer(item))) turns.push([item])
    else turns[turns.length - 1]!.push(item)
  }
  return turns.flatMap((turn, index) => turnBlocks(turn, isRunning && index === turns.length - 1))
}

/**
 * The turn's answer: its last assistant row with text (or that was interrupted) that no
 * tool call follows. Commentary (`isInterim`) is never the answer.
 */
export function answerIndex(turn: readonly TranscriptItem[]): number | undefined {
  let lastTool = -1
  let index = -1
  for (let position = turn.length - 1; position >= 0; position -= 1) {
    const row = turn[position]!
    if (lastTool < 0 && row.role === 'tool') lastTool = position
    if (index < 0 && row.role === 'assistant' && !row.isInterim && (hasReplyText(row) || row.outcome === 'interrupted')) index = position
  }
  if (index < 0) return undefined
  if (lastTool > index) return undefined
  return index
}

/**
 * The turn's rows as blocks: its prompt, its work before the answer as one block, then
 * the answer (without its reasoning, which is the work's last step). A steer or a local
 * row in the middle keeps its place and splits the work around it.
 */
function turnBlocks(turn: readonly TranscriptItem[], live: boolean): GroupedBlock[] {
  const answer = answerIndex(turn)
  const blocks: GroupedBlock[] = []
  let span: TranscriptItem[] = []
  let spanStart: number | undefined
  let previousStamp: number | undefined

  const flush = (end: number, answerRow: TranscriptItem | undefined) => {
    const rows = span
    span = []
    const laterOutput = turn.slice(end).some((row) => !isBlankReply(row))
    const isLive = live && answerRow === undefined && !laterOutput
    const entries = workEntries(rows, answerRow)
    const last = entries[entries.length - 1]
    if (isLive && last?.kind === 'group') entries[entries.length - 1] = { ...last, group: { ...last.group, isLive: true } }
    const first = rows[0] ?? answerRow
    if (entries.length === 0 || first === undefined) {
      for (const row of rows) blocks.push({ kind: 'item', item: row })
      return
    }
    const ended = answerRow?.timestamp ?? [...rows].reverse().find((row) => row.timestamp !== undefined)?.timestamp
    const work: TurnWork = { id: 'work-' + first.id, items: rows, entries, isLive, wasInterrupted: answerRow?.outcome === 'interrupted' }
    if (spanStart !== undefined) work.startedAt = spanStart
    if (!isLive && ended !== undefined) work.endedAt = ended
    blocks.push({ kind: 'work', work })
  }

  turn.forEach((row, index) => {
    if (index === answer) {
      flush(index + 1, row)
      blocks.push({ kind: 'item', item: withoutReasoning(row) })
    } else if ((row.role === 'assistant' || row.role === 'tool') && (answer === undefined || index < answer)) {
      if (span.length === 0) spanStart = previousStamp
      span.push(row)
    } else {
      flush(index, undefined)
      blocks.push({ kind: 'item', item: row })
    }
    previousStamp = row.timestamp ?? previousStamp
  })
  flush(turn.length, undefined)
  return blocks
}

/** The work's second layer: commentary, cards, and the steps between them in groups. A row's text comes before its reasoning and calls. */
function workEntries(span: readonly TranscriptItem[], answer: TranscriptItem | undefined): WorkEntry[] {
  const entries: WorkEntry[] = []
  let steps: WorkStep[] = []
  const close = () => {
    const first = steps[0]
    if (!first) return
    entries.push({ kind: 'group', id: 'group-' + first.id, group: { id: 'group-' + first.id, steps, isLive: false } })
    steps = []
  }
  const think = (item: TranscriptItem): WorkStep => ({ kind: 'think', id: 'think-' + item.id, item })
  for (const row of span) {
    if (row.role === 'assistant') {
      if (hasReplyText(row)) {
        close()
        const item = withoutReasoning(row)
        entries.push({ kind: 'commentary', id: item.id, item })
      }
      if (row.reasoning) steps.push(think(row))
    } else if (row.role === 'tool') {
      if (isCardTool(row)) {
        close()
        entries.push({ kind: 'card', id: row.id, item: row })
      } else {
        steps.push({ kind: 'tool', id: row.id, item: row })
      }
    }
  }
  if (answer?.reasoning) steps.push(think(answer))
  close()
  return entries
}
