import { useState } from 'react'
import {
  describeError, offeredApprovalChoices, requestKind,
  type ApprovalChoice, type ChatSession, type ServerRequest,
} from '@talaria/hermes-core'
import { ClarifyCard } from '../composer/cards/ClarifyCard.tsx'
import styles from './RequestCard.module.css'

const choiceTitles: Record<ApprovalChoice, string> = {
  once: 'Allow Once',
  session: 'Allow for Session',
  always: 'Always Allow',
  deny: 'Deny',
}

/**
 * A card for a request the agent waits on (the Mac's `RequestCardView`): an approval, a
 * sudo password or a secret, on an orange surface. Clarify questions are package F's card.
 */
export function RequestCard({ chat, request }: { chat: ChatSession; request: ServerRequest }) {
  const [value, setValue] = useState('')
  const [error, setError] = useState<string>()
  const run = (action: () => void) => {
    setError(undefined)
    try { action() } catch (thrown) { setError(describeError(thrown)) }
  }
  const kind = requestKind(request)
  if (kind.kind === 'clarify') return <ClarifyCard key={request.id} chat={chat} request={request} clarify={kind.clarify} />
  const valueEntry = (
    <form className={styles.entry} onSubmit={(event) => {
      event.preventDefault()
      if (value !== '') run(() => chat.answerValue(request, value))
    }}>
      <input className={styles.input} type="password" placeholder="Value" aria-label="Value" autoComplete="off"
        value={value} onChange={(event) => setValue(event.target.value)} />
      <button type="submit" className={styles.primary} disabled={value === ''}>Send</button>
      <button type="button" className={styles.button} onClick={() => run(() => chat.answerValue(request, ''))}>Skip</button>
    </form>
  )
  let content
  switch (kind.kind) {
    case 'approval': {
      const approval = kind.approval
      content = (
        <>
          <h3 className={styles.title}>Approval needed</h3>
          {approval.description && <p className={styles.text}>{approval.description}</p>}
          {approval.command && <pre className={styles.command}>{approval.command}</pre>}
          <div className={styles.actions}>
            {offeredApprovalChoices(approval).map((choice) => (
              <button key={choice} type="button" className={choice === 'deny' ? styles.destructive : styles.button}
                onClick={() => run(() => chat.answerApproval(request, choice))}>{choiceTitles[choice]}</button>
            ))}
          </div>
        </>
      )
      break
    }
    case 'sudo':
      content = (
        <>
          <h3 className={styles.title}>Sudo password requested</h3>
          {kind.sudo.command && <pre className={styles.command}>{kind.sudo.command}</pre>}
          {valueEntry}
        </>
      )
      break
    case 'secret':
      content = (
        <>
          <h3 className={styles.title}>{kind.secret.prompt}</h3>
          <span className={styles.envVar}>{kind.secret.env_var}</span>
          {valueEntry}
        </>
      )
      break
    default:
      content = (
        <>
          <h3 className={styles.title}>Unsupported request: {request.method}</h3>
          <div className={styles.actions}>
            <button type="button" className={styles.button} onClick={() => run(() => chat.answerValue(request, ''))}>Dismiss</button>
          </div>
        </>
      )
  }
  return (
    <section className={styles.card} aria-label="Request">
      {content}
      {error && <p className={styles.error} role="alert">{error}</p>}
    </section>
  )
}
