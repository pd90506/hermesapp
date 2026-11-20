import type { JSONValue } from '../../protocol/jsonrpc.ts'
import { isSteer, type TranscriptItem } from '../items.ts'

export type TodoStatus = 'pending' | 'in_progress' | 'completed' | 'cancelled'

export interface TodoItem {
  id: string
  content: string
  status: TodoStatus
  /** Another item's id: this one is its subtask. */
  parent?: string
}

/** One line of the list as shown: subtasks under their parent, one level in per depth. */
export interface TodoRow {
  item: TodoItem
  depth: number
}

/**
 * The task list Hermes's Todo tool keeps for a session (`tools/todo_tool.py`), as the
 * chat shows it above the composer (HermesKit's `TodoPlan`).
 *
 * Every Todo tool call answers the whole list and its revision
 * (`{"todos": [{id, content, status, parent?}], "revision": n, "summary": {…}}`,
 * `todo_tool.py:218`), and that result is the tool row's: live from `tool.complete`,
 * stored as the tool row's content. So the list is read from the transcript's newest
 * Todo row, and a resumed chat finds it the same way once its newest page is read.
 */
export interface TodoPlan {
  items: readonly TodoItem[]
  revision: number
}

/** The Todo tool's names: `todo_list`, its legacy alias `todo`, and the `tool_call` bridge. */
const todoToolNames: ReadonlySet<string> = new Set(['todo_list', 'todo', 'tool_call'])
const statuses: ReadonlySet<string> = new Set(['pending', 'in_progress', 'completed', 'cancelled'])

/** Items that count toward the progress: cancelled ones count on neither side (Desktop's `$todoProgressBySession`). */
export const todoTotal = (plan: TodoPlan): number => plan.items.filter((item) => item.status !== 'cancelled').length
export const todoCompleted = (plan: TodoPlan): number => plan.items.filter((item) => item.status === 'completed').length
/** No item is pending or in progress. */
export const todoIsFinished = (plan: TodoPlan): boolean =>
  !plan.items.some((item) => item.status === 'pending' || item.status === 'in_progress')

/** Parents before their subtasks, in list order. A missing or circular parent leaves the item at the top (Desktop's `todoTree`). */
export function todoRows(plan: TodoPlan): TodoRow[] {
  const ids = new Set(plan.items.map((item) => item.id))
  const children = new Map<string, TodoItem[]>()
  const roots: TodoItem[] = []
  for (const item of plan.items) {
    if (item.parent !== undefined && item.parent !== item.id && ids.has(item.parent)) {
      children.set(item.parent, [...(children.get(item.parent) ?? []), item])
    } else {
      roots.push(item)
    }
  }
  const rows: TodoRow[] = []
  const seen = new Set<string>()
  const walk = (item: TodoItem, depth: number): void => {
    if (seen.has(item.id)) return
    seen.add(item.id)
    rows.push({ item, depth })
    for (const child of children.get(item.id) ?? []) walk(child, depth + 1)
  }
  for (const root of roots) walk(root, 0)
  for (const item of plan.items) {
    if (seen.has(item.id)) continue
    seen.add(item.id)
    rows.push({ item, depth: 0 })
  }
  return rows
}

/**
 * A Todo result: the object, or JSON text holding it. Undefined for anything else, such
 * as a tool error. Items without an id, content or known status are left out (`parseTodos`).
 */
export function parseTodoPlan(value: JSONValue | undefined): TodoPlan | undefined {
  let result = value
  if (typeof result === 'string') {
    try { result = JSON.parse(result) as JSONValue } catch { return undefined }
  }
  if (result === null || typeof result !== 'object' || Array.isArray(result)) return undefined
  const todos = result.todos
  const revision = result.revision
  if (!Array.isArray(todos) || typeof revision !== 'number' || !Number.isInteger(revision) || revision < 0) return undefined
  const items: TodoItem[] = []
  for (const todo of todos) {
    if (todo === null || typeof todo !== 'object' || Array.isArray(todo)) continue
    const status = todo.status
    const id = field(todo.id)
    const content = field(todo.content)
    if (typeof status !== 'string' || !statuses.has(status) || id === undefined || content === undefined) continue
    const parent = field(todo.parent)
    items.push({ id, content, status: status as TodoStatus, ...(parent !== undefined ? { parent } : {}) })
  }
  return { items, revision }
}

function field(value: JSONValue | undefined): string | undefined {
  let text: string | undefined
  if (typeof value === 'string') text = value
  else if (typeof value === 'number' && Number.isFinite(value)) text = String(value)
  const trimmed = text?.trim()
  return trimmed ? trimmed : undefined
}

/**
 * The list to show above the composer, or undefined (HermesKit's `TodoPlan.current`).
 *
 * The newest Todo row's list, while it is the current plan:
 * - Finished, it stays until the next prompt, then goes.
 * - Unfinished, it also stays while a turn runs after a later prompt (the agent may take
 *   it up again). A turn that ended without touching it left it behind, as Desktop drops
 *   a list still open at turn end (`clearActiveSessionTodos`).
 *
 * An empty list (the agent cleared it) shows nothing.
 */
export function currentTodoPlan(items: readonly TranscriptItem[], isRunning: boolean): TodoPlan | undefined {
  let promptedSince = false
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index]!
    if (item.role === 'user') {
      if (!isSteer(item)) promptedSince = true
      continue
    }
    if (item.role !== 'tool') continue
    const name = item.tool?.name ?? item.toolName
    if (name === undefined || !todoToolNames.has(name) || item.tool?.phase === 'failed') continue
    const plan = parseTodoPlan(item.tool?.result)
    if (!plan) continue
    if (plan.items.length === 0 || (promptedSince && !(isRunning && !todoIsFinished(plan)))) return undefined
    return plan
  }
  return undefined
}

const cache = new WeakMap<readonly TranscriptItem[], { isRunning: boolean; plan: TodoPlan | undefined }>()

/** `currentTodoPlan`, worked out once per list of rows (a chat view's `items` is replaced on every change). */
export function todoPlanOf(items: readonly TranscriptItem[], isRunning: boolean): TodoPlan | undefined {
  const hit = cache.get(items)
  if (hit && hit.isRunning === isRunning) return hit.plan
  const plan = currentTodoPlan(items, isRunning)
  cache.set(items, { isRunning, plan })
  return plan
}

/** "3/5 tasks", as Claude Code's pill (the Mac's `TodoPillText`). */
export function todoTitle(plan: TodoPlan): string {
  const total = todoTotal(plan)
  return `${todoCompleted(plan)}/${total} ${total === 1 ? 'task' : 'tasks'}`
}

export function todoAccessibilityLabel(plan: TodoPlan): string {
  if (todoIsFinished(plan)) return `All tasks complete, ${todoCompleted(plan)} of ${todoTotal(plan)}`
  return `Tasks, ${todoCompleted(plan)} of ${todoTotal(plan)} complete`
}
