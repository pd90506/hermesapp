import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { ClipboardPolicy } from '@talaria/hermes-core'
import { actionIcons } from '../../chat/blocks/media/icons.ts'
import type { ComposerSlotProps } from '../slots.ts'
import { attachIncoming, incomingFromFile, pickFiles, type IncomingFile } from './intake.ts'
import styles from './Attachments.module.css'

/**
 * The toolbar's attach button (the Mac's `+` menu, whose one item is Choose Files…): the
 * system's open dialog, any type, several at once. It also takes the composer's other
 * sources while its chat is on screen:
 * - a paste into the composer of files or an image (Finder's or Explorer's Copy, a
 *   screenshot, a browser's Copy Image); text with a file beside it stays text;
 * - files dragged onto the window, which shows where they will go.
 */
export function AttachButton({ composer }: ComposerSlotProps) {
  const tray = composer.attachments
  const anchor = useRef<HTMLButtonElement>(null)
  const [dragging, setDragging] = useState(false)

  const report = (message: string) => composer.reportError(message)
  const attach = (files: IncomingFile[]) => { if (files.length > 0) void attachIncoming(tray, files, report) }

  useEffect(() => {
    const card = anchor.current?.closest('[data-composer-card]') ?? anchor.current?.parentElement?.parentElement ?? null
    const onPaste = (event: ClipboardEvent) => {
      const data = event.clipboardData
      if (!data || data.files.length === 0) return
      const target = event.target as Node | null
      // The composer's text, or nothing editable (focus elsewhere in the chat).
      if (!(card && target && card.contains(target)) && isEditable(target)) return
      const files = [...data.files]
      const decision = ClipboardPolicy.decide({
        fileCount: files.length, text: data.getData('text/plain'), fileNames: files.map((file) => file.name),
      })
      if (decision !== 'files') return
      event.preventDefault()
      attach(files.map(incomingFromFile))
    }
    let depth = 0
    const hasFiles = (event: DragEvent) => event.dataTransfer?.types.includes('Files') ?? false
    const onDragEnter = (event: DragEvent) => {
      if (!hasFiles(event)) return
      event.preventDefault()
      depth += 1
      setDragging(true)
    }
    const onDragOver = (event: DragEvent) => {
      if (!hasFiles(event)) return
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
    }
    const onDragLeave = (event: DragEvent) => {
      if (!hasFiles(event)) return
      depth = Math.max(0, depth - 1)
      if (depth === 0) setDragging(false)
    }
    const onDrop = (event: DragEvent) => {
      depth = 0
      setDragging(false)
      if (!hasFiles(event)) return
      event.preventDefault()
      attach([...(event.dataTransfer?.files ?? [])].map(incomingFromFile))
    }
    document.addEventListener('paste', onPaste)
    window.addEventListener('dragenter', onDragEnter)
    window.addEventListener('dragover', onDragOver)
    window.addEventListener('dragleave', onDragLeave)
    window.addEventListener('drop', onDrop)
    return () => {
      document.removeEventListener('paste', onPaste)
      window.removeEventListener('dragenter', onDragEnter)
      window.removeEventListener('dragover', onDragOver)
      window.removeEventListener('dragleave', onDragLeave)
      window.removeEventListener('drop', onDrop)
    }
  })

  return (
    <>
      <button ref={anchor} type="button" className={styles.attach} aria-label="Attach Files" title="Attach files…"
        onClick={() => { pickFiles().then(attach, (error: unknown) => report(String(error))) }}>
        <svg viewBox="0 0 16 16" aria-hidden="true"><path d={actionIcons.plus} /></svg>
      </button>
      {dragging && createPortal(
        <div className={styles.dropOverlay} aria-hidden="true">
          <span className={styles.dropLabel}>Drop files to attach</span>
        </div>,
        document.body,
      )}
    </>
  )
}

function isEditable(target: Node | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  return target.isContentEditable || target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement
}
