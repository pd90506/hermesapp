import { useEffect, useRef, useState, type ReactNode } from 'react'
import styles from './Dialogs.module.css'

/**
 * A modal question over the window, on the platform's `<dialog>` (the Mac's `.alert`
 * and `.confirmationDialog`, WinUI's ContentDialog): a title, a message, and buttons,
 * the default one last. Escape cancels.
 */
function Modal({ title, message, children, actions, onCancel, label }: {
  title: string; message?: string; children?: ReactNode; actions: ReactNode; onCancel: () => void; label: string
}) {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dialog = ref.current
    if (!dialog) return
    if (typeof dialog.showModal === 'function') dialog.showModal()
    else dialog.setAttribute('open', '')
    return () => { if (typeof dialog.close === 'function') dialog.close() }
  }, [])
  return (
    <dialog ref={ref} className={styles.dialog} aria-label={label}
      onCancel={(event) => { event.preventDefault(); onCancel() }}
      onKeyDown={(event) => { if (event.key === 'Escape') { event.preventDefault(); onCancel() } }}>
      <h2 className={styles.title}>{title}</h2>
      {message && <p className={styles.message}>{message}</p>}
      {children}
      <div className={styles.actions}>{actions}</div>
    </dialog>
  )
}

/** "Rename Chat", with the title in a field (the Mac's alert with a TextField). */
export function RenameDialog({ initial, onRename, onCancel }: {
  initial: string; onRename: (title: string) => void; onCancel: () => void
}) {
  const [title, setTitle] = useState(initial)
  return (
    <Modal title="Rename Chat" label="Rename Chat" onCancel={onCancel} actions={<>
      <button type="button" className={styles.button} onClick={onCancel}>Cancel</button>
      <button type="submit" form="rename-chat" className={styles.button} data-default>Rename</button>
    </>}>
      <form id="rename-chat" onSubmit={(event) => { event.preventDefault(); onRename(title) }}>
        <input className={styles.field} aria-label="Title" placeholder="Title" value={title} autoFocus
          onChange={(event) => setTitle(event.target.value)} onFocus={(event) => event.target.select()} />
      </form>
    </Modal>
  )
}

/** "Delete “Title”?", for good (the Mac's confirmation dialog). */
export function DeleteDialog({ title, onDelete, onCancel }: { title: string; onDelete: () => void; onCancel: () => void }) {
  return (
    <Modal title={`Delete “${title}”?`} label="Delete Chat" message="Its messages are deleted from Hermes for good."
      onCancel={onCancel} actions={<>
        <button type="button" className={styles.button} onClick={onCancel} autoFocus>Cancel</button>
        <button type="button" className={styles.button} data-destructive onClick={onDelete}>Delete</button>
      </>} />
  )
}

/** A failure the user acknowledges ("Couldn't change the avatar"). */
export function AlertDialog({ title, message, onClose }: { title: string; message: string; onClose: () => void }) {
  return (
    <Modal title={title} label={title} message={message} onCancel={onClose} actions={
      <button type="button" className={styles.button} data-default onClick={onClose} autoFocus>OK</button>
    } />
  )
}
