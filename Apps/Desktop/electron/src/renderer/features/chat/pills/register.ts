import { todoPlanOf, type ChatSession } from '@talaria/hermes-core'
import { useSnapshot } from '../../../app/hooks.ts'
import { registerChatPill } from '../overlay.ts'
import { BackgroundPill } from './BackgroundPill.tsx'
import { SubagentsPill } from './SubagentsPill.tsx'
import { TodoPill } from './TodoPill.tsx'

// Package J's pills, after the scroll-to-bottom button (100) as on the Mac's row: the
// background tasks, the task list, then the subagents.
registerChatPill({ id: 'background', order: 110, Pill: BackgroundPill,
  useShown: (chat) => useSnapshot(chat.activity).processes.processes.length > 0 })
registerChatPill({ id: 'todo', order: 120, Pill: TodoPill, useShown: useTodoShown })
registerChatPill({ id: 'subagents', order: 130, Pill: SubagentsPill,
  useShown: (chat) => useSnapshot(chat.activity).subagents.live.length > 0 })

function useTodoShown(chat: ChatSession): boolean {
  const view = useSnapshot(chat)
  return todoPlanOf(view.items, view.isRunning) !== undefined
}
