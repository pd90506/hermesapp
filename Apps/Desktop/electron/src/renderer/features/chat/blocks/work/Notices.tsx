import { useLayoutEffect, useRef, useState } from 'react'
import { backgroundNotice, reviewNote } from '@talaria/hermes-core'
import type { BlockProps } from '../registry.ts'
import { FoldButton } from './Fold.tsx'
import { useRemembered } from './remembered.ts'
import { ToolTextBox } from './ToolCall.tsx'
import { WorkIcon } from './WorkIcon.tsx'
import styles from './Work.module.css'

/**
 * A background notice Hermes wrote as a user turn (`BackgroundNotice`): one line, as
 * Desktop's `BackgroundResult` shows it, opening to the command and output.
 */
export function BackgroundNoticeBlock({ block, chat }: BlockProps) {
  const notice = block.kind === 'item' ? backgroundNotice(block.item) : undefined
  const [open, setOpen] = useRemembered(chat, `notice:${block.id}`, false)
  if (!notice) return null
  const expandable = notice.detail !== ''
  return (
    <div className={styles.notice} data-testid="background-notice">
      <FoldButton expanded={open} onToggle={setOpen} chevron={expandable ? 'disclosure' : 'none'} disabled={!expandable}
        className={styles.noticeLine}>
        <span className={styles.glyph}><WorkIcon name="bell" /></span>
        <span className={styles.title}>{notice.headline}</span>
      </FoldButton>
      {open && expandable && (
        <div className={styles.noticeBody}><ToolTextBox text={notice.detail} kind="code" maxLines={12} /></div>
      )}
    </div>
  )
}

/**
 * What the self-improvement review saved after a turn (`ReviewNote`), as Desktop draws it
 * (`system-message.tsx`): a glowing brain, the label in a gold-to-purple gradient, the
 * detail in purple. A detail too long for one line folds to one line with a chevron at
 * the end, and opens in place on a click (the user, 2026-11-03).
 */
export function ReviewNoteBlock({ block, chat }: BlockProps) {
  const note = block.kind === 'item' ? reviewNote(block.item) : undefined
  const [open, setOpen] = useRemembered(chat, `review:${block.id}`, false)
  const detail = useRef<HTMLSpanElement>(null)
  const [overflows, setOverflows] = useState(false)
  useLayoutEffect(() => {
    const element = detail.current
    if (!element || open) return
    const measure = () => setOverflows(element.scrollWidth > element.clientWidth + 1)
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    return () => observer.disconnect()
  }, [open, note?.detail])
  if (!note) return null
  const content = (
    <>
      <span className={styles.glyph}><WorkIcon name="brain" tone="review" /></span>
      <span className={styles.reviewLabel}>{note.label}</span>
      {note.detail !== '' && <span ref={detail} className={styles.reviewDetail} data-open={open || undefined}>{note.detail}</span>}
    </>
  )
  const folds = overflows || open
  return (
    <div className={styles.review} data-testid="review-note">
      <FoldButton expanded={open} onToggle={setOpen} chevron={folds ? 'disclosure' : 'none'} disabled={!folds}
        className={styles.reviewFold}>{content}</FoldButton>
    </div>
  )
}
