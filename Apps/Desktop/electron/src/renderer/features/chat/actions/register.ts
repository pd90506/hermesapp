import { blockRenderer, registerBlockRenderer } from '../blocks/registry.ts'
import { withCopyMenu, withMessageActions } from './MessageActions.tsx'

/**
 * Package G's registration: wraps the renderers registered before it, so whichever
 * package draws a row, prompts and replies get the action bar and every row the copy
 * menu. Called once, after the other packages' lines in `registered-blocks.ts`.
 */
export function addMessageActions(): void {
  const wrap = (kind: string, wrapper: (inner: NonNullable<ReturnType<typeof blockRenderer>>) => ReturnType<typeof withCopyMenu>) => {
    const inner = blockRenderer(kind)
    if (inner) registerBlockRenderer(kind, wrapper(inner))
  }
  wrap('user', (inner) => withMessageActions(inner, 'trailing'))
  wrap('assistant', (inner) => withMessageActions(inner, 'leading'))
  wrap('system', withCopyMenu)
  wrap('tool', withCopyMenu)
}
