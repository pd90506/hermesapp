// Every block renderer, registered by importing its module once (blocks/registry.ts).
// One line per package, in package order; a later registration of a kind replaces an
// earlier one.
import { registerBlockRenderer } from './registry.ts'
import { AssistantBlock, SystemBlock, ToolBlock, UserBlock } from './MessageBlocks.tsx'

// A
registerBlockRenderer('user', UserBlock)
registerBlockRenderer('assistant', AssistantBlock)
registerBlockRenderer('system', SystemBlock)
registerBlockRenderer('tool', ToolBlock)
