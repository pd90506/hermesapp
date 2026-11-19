import { useEffect, useRef } from 'react'
import styles from './CronJobEditor.module.css'

/** The Mac's confirmation dialog for Delete…: a modal `<dialog>`, Cancel and the destructive action. */
export function ConfirmDialog({ title, message, confirm, onConfirm, onCancel }: {
  title: string
  message: string
  confirm: string
  onConfirm: () => void
  onCancel: () => void
}) {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal?.()
  }, [])
  return (
    <dialog ref={ref} className={`${styles.dialog} ${styles.confirm}`} aria-label={title}
      onCancel={(event) => { event.preventDefault(); onCancel() }}>
      <h2 className={styles.heading}>{title}</h2>
      <p className={styles.footer}>{message}</p>
      <div className={styles.actions}>
        <button type="button" className={styles.button} onClick={onCancel}>Cancel</button>
        <button type="button" className={styles.destructive} onClick={onConfirm} autoFocus>{confirm}</button>
      </div>
    </dialog>
  )
}
