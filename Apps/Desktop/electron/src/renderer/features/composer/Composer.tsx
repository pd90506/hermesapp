import { useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react'
import { describeError, type ChatComposer, type ChatSession } from '@talaria/hermes-core'
import { useSnapshot } from '../../app/hooks.ts'
import { composerKeyAction } from './keys.ts'
import { composerSlots, handleComposerKey, type ComposerSlotArea } from './slots.ts'
import './registered-slots.ts'
import styles from './Composer.module.css'

/**
 * The chat's composer (the Mac's `ComposerView`, the parts package A owns): a card over
 * the chat with the auto-growing text area and the toolbar's Send / Stop. Other packages
 * fill the slots (`slots.ts`): cards over it, attachments, the `+` menu, model and effort.
 */
export function Composer({ chat, composer, isConnected }: { chat: ChatSession; composer: ChatComposer; isConnected: boolean }) {
  const view = useSnapshot(composer)
  const chatView = useSnapshot(chat)
  const [stopError, setStopError] = useState<string>()
  const text = useRef<HTMLTextAreaElement>(null)

  // The text area grows with its text up to about eight lines, then scrolls.
  useLayoutEffect(() => {
    const element = text.current
    if (!element) return
    element.style.height = 'auto'
    element.style.height = `${element.scrollHeight}px`
  }, [view.draft])

  useLayoutEffect(() => { text.current?.focus() }, [chat])

  const submit = () => { if (composer.canSubmit) void composer.submit() }
  const stop = () => {
    setStopError(undefined)
    chat.interrupt().catch((error: unknown) => setStopError(describeError(error)))
  }
  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    const composing = event.nativeEvent.isComposing || event.keyCode === 229
    if (!composing && handleComposerKey(event, { chat, composer })) {
      event.preventDefault()
      return
    }
    const action = composerKeyAction({
      key: event.key, shiftKey: event.shiftKey, altKey: event.altKey, metaKey: event.metaKey, ctrlKey: event.ctrlKey,
      isComposing: event.nativeEvent.isComposing || event.keyCode === 229,
    })
    if (action === 'send') {
      event.preventDefault()
      submit()
    } else if (action === 'newline' && !event.shiftKey) {
      // Option- / Alt-Return: a line break where the caret is, undoable as typing.
      event.preventDefault()
      event.currentTarget.ownerDocument.execCommand('insertText', false, '\n')
    }
  }
  const error = view.error ?? stopError
  const slot = (area: ComposerSlotArea) =>
    composerSlots(area).map(({ id, Slot }) => <Slot key={id} chat={chat} composer={composer} />)
  const cards = slot('cards')

  return (
    <div className={styles.stack}>
      {cards.length > 0 && <div className={styles.cards}>{cards}</div>}
      <div className={styles.card}>
        {error && (
          <div className={styles.error} role="alert">
            <span className={styles.errorText}>{error}</span>
            <button type="button" className={styles.dismiss} aria-label="Dismiss" title="Dismiss"
              onClick={() => { composer.clearError(); setStopError(undefined) }}>
              <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" /></svg>
            </button>
          </div>
        )}
        {slot('attachments')}
        <div className={styles.textRow}>
          <textarea ref={text} className={styles.text} rows={1} value={view.draft} placeholder="Message Hermes"
            aria-label="Message" spellCheck onKeyDown={onKeyDown} onChange={(event) => composer.setDraft(event.target.value)} />
        </div>
        <div className={styles.toolbar}>
          {slot('leading')}
          <span className={styles.spacer} />
          {slot('modelEffort')}
          {slot('trailing')}
          <div className={styles.sendArea}>
            {chatView.isRunning ? (
              <>
                {(composer.canSubmit || view.isSubmitting) && (view.isSubmitting
                  ? <CancelSend quiet onClick={() => composer.cancelSubmit()} />
                  : <CircleButton quiet label="Send" title="Queue it to send after the current reply. Above the message box you can steer it in now or cancel it." disabled={!composer.canSubmit} onClick={submit} icon="send" />)}
                <CircleButton label="Stop" title="Stop the reply" disabled={!isConnected} onClick={stop} icon="stop" />
              </>
            ) : view.isSubmitting ? (
              <CancelSend onClick={() => composer.cancelSubmit()} />
            ) : (
              <CircleButton label="Send" title="Send (Return)" disabled={!composer.canSubmit} onClick={submit} icon="send" />
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

const icons = {
  send: 'M8 13V3.5M3.5 7.5 8 3l4.5 4.5',
  stop: 'M4.5 4.5h7v7h-7z',
  cancel: 'M5 5l6 6M11 5l-6 6',
} as const

function CircleButton({ label, title, icon, onClick, disabled = false, quiet = false, busy = false }: {
  label: string
  title: string
  icon: keyof typeof icons
  onClick: () => void
  disabled?: boolean
  quiet?: boolean
  busy?: boolean
}) {
  return (
    <button type="button" className={quiet ? styles.quiet : styles.prominent} aria-label={label} title={title}
      disabled={disabled} onClick={onClick} data-icon={icon}>
      {busy && <span className={styles.spinner} aria-hidden="true" />}
      <svg className={busy ? styles.busyIcon : styles.icon} viewBox="0 0 16 16" aria-hidden="true"><path d={icons[icon]} /></svg>
    </button>
  )
}

/** Sending: a spinner round a ✕ that stops the send while it still waits to go out. */
function CancelSend({ onClick, quiet = false }: { onClick: () => void; quiet?: boolean }) {
  return <CircleButton label="Cancel Send" title="Sending… click to cancel" icon="cancel" busy quiet={quiet} onClick={onClick} />
}
