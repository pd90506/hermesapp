import { registerChatPill } from '../overlay.ts'
import { BackgroundPill } from './BackgroundPill.tsx'
import { SubagentsPill } from './SubagentsPill.tsx'
import { TodoPill } from './TodoPill.tsx'

// Package J's pills, after the scroll-to-bottom button (100) as on the Mac's row: the
// background tasks, the task list, then the subagents.
registerChatPill({ id: 'background', order: 110, Pill: BackgroundPill })
registerChatPill({ id: 'todo', order: 120, Pill: TodoPill })
registerChatPill({ id: 'subagents', order: 130, Pill: SubagentsPill })
