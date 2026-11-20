import { useEffect } from 'react'
import {
  todoAccessibilityLabel, todoCompleted, todoIsFinished, todoPlanOf, todoRows, todoTitle, todoTotal,
  type TodoPlan, type TodoStatus,
} from '@talaria/hermes-core'
import { useSnapshot } from '../../../app/hooks.ts'
import type { ChatPillProps } from '../overlay.ts'
import { useOpenCard } from './open-card.ts'
import { PillButton, PillCard } from './PillCard.tsx'
import styles from './Pills.module.css'

/**
 * The agent's task list (`currentTodoPlan`), as Claude Code shows its own: a pill over
 * the composer ("3/5 tasks", a ring filling as tasks finish), which opens into a card,
 * one line per task down a timeline, the done ones struck through. It goes with the list.
 */
export function TodoPill({ chat }: ChatPillProps) {
  const view = useSnapshot(chat)
  const plan = todoPlanOf(view.items, view.isRunning)
  const [open, setOpen] = useOpenCard(chat, 'todo')
  useEffect(() => { if (!plan && open) setOpen(false) }, [plan, open, setOpen])
  if (!plan) return null
  return (
    <div className={styles.slot}>
      <PillButton icon={<ProgressRing plan={plan} />} title={todoTitle(plan)} label={todoAccessibilityLabel(plan)}
        hint="Shows the task list" open={open} onToggle={() => setOpen(!open)} testID="todoPill" />
      {open && (
        <PillCard title={todoIsFinished(plan) ? `${todoTitle(plan)} complete` : todoTitle(plan)} onClose={() => setOpen(false)}
          testID="todoPanel">
          <ol className={styles.todoList}>
            {todoRows(plan).map((row, index, rows) => (
              <li key={row.item.id} className={styles.todoRow} data-status={row.item.status}
                data-last={index === rows.length - 1 || undefined}
                style={{ paddingInlineStart: `calc(${row.depth} * var(--pill-todo-indent))` }}
                aria-label={`${row.item.content}, ${statusText(row.item.status)}`}>
                <span className={styles.todoMark} aria-hidden="true"><TodoMark status={row.item.status} /></span>
                <span className={styles.todoText}>{row.item.content}</span>
              </li>
            ))}
          </ol>
        </PillCard>
      )}
    </div>
  )
}

/** The pill's mark: a ring filling with the tasks done, a check once none is left. */
function ProgressRing({ plan }: { plan: TodoPlan }) {
  if (todoIsFinished(plan)) {
    return (
      <svg className={styles.ringDone} viewBox="0 0 16 16"><circle cx="8" cy="8" r="7" /><path d="M5 8.2 7.1 10.3 11 6" /></svg>
    )
  }
  const total = todoTotal(plan)
  const fraction = total > 0 ? todoCompleted(plan) / total : 0
  const circumference = 2 * Math.PI * 6
  return (
    <svg className={styles.ring} viewBox="0 0 16 16">
      <circle className={styles.ringTrack} cx="8" cy="8" r="6" />
      <circle className={styles.ringFill} cx="8" cy="8" r="6" strokeDasharray={`${fraction * circumference} ${circumference}`} />
    </svg>
  )
}

function TodoMark({ status }: { status: TodoStatus }) {
  switch (status) {
    case 'completed': return <svg viewBox="0 0 16 16"><path d="M5 8.2 7.1 10.3 11 6" /></svg>
    case 'cancelled': return <svg viewBox="0 0 16 16"><path d="M5.5 5.5l5 5M10.5 5.5l-5 5" /></svg>
    case 'in_progress': return <span className={styles.todoDot} />
    case 'pending': return null
  }
}

function statusText(status: TodoStatus): string {
  switch (status) {
    case 'completed': return 'Done'
    case 'in_progress': return 'In progress'
    case 'pending': return 'Not started'
    case 'cancelled': return 'Cancelled'
  }
}
