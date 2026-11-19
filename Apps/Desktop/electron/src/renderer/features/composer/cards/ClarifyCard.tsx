import { useState } from 'react'
import {
  ClarifyForm, allowsMultipleClarifyChoices, bareClarifyChoice, describeError, offeredClarifyChoices,
  type ChatSession, type ClarifyQuestion, type ClarifyRequest, type ServerRequest,
} from '@talaria/hermes-core'
import styles from './ClarifyCard.module.css'

/**
 * The clarify card (the Mac's `ClarifyCardView`, Desktop's batch card): Hermes's questions
 * one at a time, their choices as numbered rows to click and a row to type an answer;
 * a strip of numbers switches question. Every answer goes out together (`ClarifyForm`);
 * Skip cancels the request. On a plain surface: a question is no warning.
 */
export function ClarifyCard({ chat, request, clarify }: { chat: ChatSession; request: ServerRequest; clarify: ClarifyRequest }) {
  const [form, setForm] = useState(() => ClarifyForm.start(clarify))
  const [error, setError] = useState<string>()
  const run = (answers: Record<string, string | null> | null) => {
    setError(undefined)
    try { chat.answerClarify(request, answers) } catch (thrown) { setError(describeError(thrown)) }
  }
  const count = form.questions.length
  const question = form.activeQuestion
  return (
    <section className={styles.card} aria-label="Question from Hermes">
      <header className={styles.header}>
        <svg className={styles.headerIcon} viewBox="0 0 16 16" aria-hidden="true">
          <path d="M3 2.5h10a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1H7l-3 2.5V11.5H3a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1zM6.3 5.6a1.7 1.7 0 1 1 2.4 1.6c-.5.2-.7.6-.7 1.1M8 9.6h.01" />
        </svg>
        <h3 className={styles.title}>{count > 1 ? `Hermes has ${count} questions` : 'Hermes has a question'}</h3>
        {count > 1 && <span className={styles.progress}>{form.answeredCount} of {count} answered</span>}
      </header>
      {count > 1 && (
        <div className={styles.strip} role="tablist" aria-label="Questions">
          {form.questions.map((other, index) => (
            <button key={other.qid} type="button" role="tab" className={styles.tab}
              aria-selected={index === form.activeIndex} onClick={() => setForm(form.show(index))}>
              {index + 1}{form.isAnswered(other) ? ' ✓' : ''}
            </button>
          ))}
        </div>
      )}
      {question && <QuestionView key={question.qid} question={question} form={form} setForm={setForm} />}
      {error && <p className={styles.error} role="alert">{error}</p>}
      <footer className={styles.footer}>
        <button type="button" className={styles.button} onClick={() => run(null)}>Skip</button>
        {form.hasNext && <button type="button" className={styles.button} onClick={() => setForm(form.show(form.activeIndex + 1))}>Next</button>}
        <button type="button" className={styles.primary} disabled={!form.canSend} onClick={() => run(form.answers)}>Send Answers</button>
      </footer>
    </section>
  )
}

function QuestionView({ question, form, setForm }: {
  question: ClarifyQuestion
  form: ClarifyForm
  setForm: (form: ClarifyForm) => void
}) {
  const choices = offeredClarifyChoices(question)
  const multiple = allowsMultipleClarifyChoices(question)
  const other = form.selection(question).other
  return (
    <div className={styles.question}>
      <div className={styles.prompt}>
        <p className={styles.questionText}>{question.question}</p>
        {choices.length > 0 && <span className={styles.hint}>{multiple ? 'Select all that apply' : 'Pick one'}</span>}
      </div>
      {choices.map((choice, index) => {
        const label = bareClarifyChoice(choice)
        const picked = form.isPicked(choice, question)
        return (
          <button key={index} type="button" className={styles.row} data-picked={picked || undefined}
            role={multiple ? 'checkbox' : 'radio'} aria-checked={picked} aria-label={label}
            onClick={() => setForm(form.pick(choice, question))}>
            <span className={styles.badge} aria-hidden="true">{index + 1}</span>
            <span className={styles.choice}>
              <span>{label}</span>
              {label !== choice && <span className={styles.recommended}>Recommended</span>}
            </span>
            {multiple
              ? <span className={styles.checkbox} aria-hidden="true">{picked && <svg viewBox="0 0 16 16"><path d="M4 8.5l2.5 2.5 5.5-6" /></svg>}</span>
              : picked && <svg className={styles.check} viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7" /></svg>}
          </button>
        )
      })}
      <label className={styles.row} data-picked={other.trim() !== '' || undefined} data-other="">
        {choices.length > 0 && <span className={styles.badge} aria-hidden="true">{choices.length + 1}</span>}
        <textarea className={styles.other} rows={1} value={other} aria-label="Your answer"
          placeholder={choices.length > 0 ? 'Other (type your answer)' : 'Type your answer…'}
          onChange={(event) => setForm(form.setOther(event.target.value, question))} />
      </label>
    </div>
  )
}
