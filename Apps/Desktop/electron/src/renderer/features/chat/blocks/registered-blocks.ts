// Every block renderer, registered by importing its module once (blocks/registry.ts).
// One line per package, in package order; a later registration of a kind replaces an
// earlier one.
import { registerBlockRenderer } from './registry.ts'
import { AssistantBlock, SystemBlock, ToolBlock, UserBlock } from './MessageBlocks.tsx'
import { BackgroundNoticeBlock, ReviewNoteBlock } from './work/Notices.tsx'
import { ToolBlock as ToolCallBlock } from './work/ToolCall.tsx'
import { TurnWorkBlock } from './work/TurnWork.tsx'

// A
registerBlockRenderer('user', UserBlock)
registerBlockRenderer('assistant', AssistantBlock)
registerBlockRenderer('system', SystemBlock)
registerBlockRenderer('tool', ToolBlock)

// C
registerBlockRenderer('work', TurnWorkBlock)
registerBlockRenderer('tool', ToolCallBlock)
registerBlockRenderer('backgroundNotice', BackgroundNoticeBlock)
registerBlockRenderer('review', ReviewNoteBlock)
