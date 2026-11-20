import { useLayoutEffect, useRef } from 'react'
import type { SlashListKey } from '@talaria/hermes-core'
import { useSnapshot } from '../../../app/hooks.ts'
import type { ComposerKeyHandler, ComposerSlotProps } from '../slots.ts'
import styles from './SlashList.module.css'

/**
 * The composer's slash-command list (the Mac's `SlashSuggestionList`, drawn as Hermes
 * Desktop's completion drawer): a panel floating just above the composer, inset from its
 * start, as tall as its rows up to `--slash-list-max-height`, then scrolling. Rows group
 * under their category; the highlighted row follows the arrows. With no rows it shows why
 * ("No matches. Try /help.", a failed lookup). Clicking a row accepts it and keeps the
 * keyboard in the composer.
 */
export function SlashList({ composer }: ComposerSlotProps) {
  const view = useSnapshot(composer.slash)
  const list = useRef<HTMLDivElement>(null)
  const rows = view.isOpen ? composer.slash.rows : []

  useLayoutEffect(() => {
    list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView?.({ block: 'nearest' })
  }, [view.selection, view.isOpen])

  useLayoutEffect(() => () => composer.slash.cancel(), [composer])

  if (!view.isOpen && view.notice === undefined) return null
  return (
    <div className={styles.anchor}>
      {view.isOpen ? (
        <div ref={list} className={styles.panel} role="listbox" aria-label="Commands" id="composer-slash-list">
          {rows.map((row) => (
            <div key={row.id} role="presentation">
              {row.header && <div className={styles.header} role="presentation">{row.header}</div>}
              <div role="option" aria-selected={row.isSelected} className={styles.row} data-selected={row.isSelected || undefined}
                onPointerDown={(event) => event.preventDefault()} onClick={() => composer.slash.acceptRow(row.id)}>
                <span className={styles.name}>{row.suggestion.item.display ?? row.suggestion.item.text}</span>
                {row.suggestion.item.meta && <span className={styles.meta}>{row.suggestion.item.meta}</span>}
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className={styles.panel} role="status">
          <div className={styles.notice}>{view.notice}</div>
        </div>
      )}
    </div>
  )
}

const keys: Record<string, SlashListKey> = {
  ArrowUp: 'up', ArrowDown: 'down', Tab: 'tab', Enter: 'accept', Escape: 'escape',
}

/**
 * The keys the text area offers the list (the Mac's `ComposerTextView.SlashKey`): arrows,
 * Tab, plain Return and Esc. Modified keys (Shift-Return, ⌘↩) stay the composer's.
 */
export const slashKeys: ComposerKeyHandler = (event, { composer }) => {
  const key = keys[event.key]
  if (!key || event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return false
  return composer.slash.handleKey(key)
}
