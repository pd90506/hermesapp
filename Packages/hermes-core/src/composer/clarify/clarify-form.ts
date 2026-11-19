import type { ClarifyQuestion, ClarifyRequest } from '../../session/types.ts'

// The clarify card's model (HermesKit's `ClarifyQuestion` helpers in
// `ServerRequests.swift` and `ClarifyForm`). Multi-select follows Desktop
// (`apps/desktop/src/store/clarify.ts:42-102`, `components/assistant-ui/clarify/pending.tsx:90-141`)
// and what the clarify tool decodes (`tools/clarify_tool.py:12,30-47`).

/** What the user picked for one question. */
export interface ClarifySelection {
  /** Picked choices, as offered (a "(Recommended)" suffix is stripped on encode). */
  readonly choices: readonly string[]
  /** The typed ("Other") answer; for a multi-select an extra value. */
  readonly other: string
}

const emptySelection: ClarifySelection = { choices: [], other: '' }

/** `MAX_CHOICE_CHARS` (`store/clarify.ts:42`, `tools/clarify_tool.py:12`). */
export const clarifyMaxChoiceCharacters = 8000

const recommended = '(Recommended)'

/** The label the tool expects back: a choice without its " (Recommended)" suffix. */
export function bareClarifyChoice(choice: string): string {
  const trimmed = choice.trim()
  if (!trimmed.toLowerCase().endsWith(recommended.toLowerCase())) return trimmed
  return trimmed.slice(0, trimmed.length - recommended.length).trim()
}

/** The choices to offer: blank and over-long ones dropped. None = an open-ended question. */
export function offeredClarifyChoices(question: ClarifyQuestion): string[] {
  return (question.choices ?? []).map((choice) => choice.trim())
    .filter((choice) => choice !== '' && [...bareClarifyChoice(choice)].length <= clarifyMaxChoiceCharacters)
}

/** Checkboxes plus an optional typed answer; `multi_select` counts only with choices. */
export function allowsMultipleClarifyChoices(question: ClarifyQuestion): boolean {
  return question.multi_select === true && offeredClarifyChoices(question).length > 0
}

/**
 * The wire answer for a selection, or `null` (skipped) when nothing is picked or typed:
 * a multi-select sends a JSON array string of the bare choices, then the typed text;
 * otherwise the first picked choice, else the typed text.
 */
export function clarifyAnswer(question: ClarifyQuestion, selection: ClarifySelection): string | null {
  const other = selection.other.trim()
  if (allowsMultipleClarifyChoices(question)) {
    const values = [...selection.choices.map(bareClarifyChoice), ...(other === '' ? [] : [other])]
    return values.length === 0 ? null : JSON.stringify(values)
  }
  const first = selection.choices[0]
  if (first !== undefined) return bareClarifyChoice(first)
  return other === '' ? null : other
}

/** Reads a locked answer (a replayed request's `answers`) back into a selection. */
export function clarifySelectionFromAnswer(question: ClarifyQuestion, answer: string): ClarifySelection {
  let values = [answer]
  if (allowsMultipleClarifyChoices(question)) {
    try {
      const parsed: unknown = JSON.parse(answer)
      if (Array.isArray(parsed) && parsed.every((value) => typeof value === 'string')) values = parsed as string[]
    } catch { /* a plain string */ }
  }
  const matched = offeredClarifyChoices(question).filter((choice) => values.includes(bareClarifyChoice(choice)))
  if (matched.length === 0) return { choices: [], other: answer }
  const bare = new Set(matched.map(bareClarifyChoice))
  return { choices: matched, other: values.filter((value) => !bare.has(value)).join(', ') }
}

/**
 * What the clarify card has staged for one request: a selection per question and the
 * question on show. Nothing reaches the server until the card sends every answer at
 * once, as Desktop's batch card does. One question shows at a time; picking a choice of
 * a single-select question moves on to the next unanswered one. Immutable: each change
 * returns a new form.
 */
export class ClarifyForm {
  readonly selections: ReadonlyMap<string, ClarifySelection>
  /** The index in `questions` of the question on show. */
  readonly activeIndex: number

  private constructor(readonly request: ClarifyRequest, selections: ReadonlyMap<string, ClarifySelection>, activeIndex: number) {
    this.selections = selections
    this.activeIndex = Math.min(Math.max(activeIndex, 0), Math.max(request.questions.length - 1, 0))
  }

  /** Starts from the answers already locked (a replayed request), on the first question without one. */
  static start(request: ClarifyRequest): ClarifyForm {
    const selections = new Map<string, ClarifySelection>()
    for (const question of request.questions) {
      const locked = request.answers?.[question.qid]
      if (typeof locked === 'string') selections.set(question.qid, clarifySelectionFromAnswer(question, locked))
    }
    const draft = new ClarifyForm(request, selections, 0)
    const first = request.questions.findIndex((question) => !draft.isAnswered(question))
    return new ClarifyForm(request, selections, first < 0 ? 0 : first)
  }

  get questions(): readonly ClarifyQuestion[] {
    return this.request.questions
  }

  get activeQuestion(): ClarifyQuestion | undefined {
    return this.questions[this.activeIndex]
  }

  selection(question: ClarifyQuestion): ClarifySelection {
    return this.selections.get(question.qid) ?? emptySelection
  }

  isPicked(choice: string, question: ClarifyQuestion): boolean {
    return this.selection(question).choices.includes(choice)
  }

  /** Whether the question would be sent with an answer rather than as skipped. */
  isAnswered(question: ClarifyQuestion): boolean {
    return clarifyAnswer(question, this.selection(question)) !== null
  }

  get answeredCount(): number {
    return this.questions.filter((question) => this.isAnswered(question)).length
  }

  /** Sending needs one answer at least; the rest go as skipped (Desktop's `canConfirm`). */
  get canSend(): boolean {
    return this.answeredCount > 0
  }

  /** The `{qid: answer}` map to send; unanswered questions are `null` (skipped). */
  get answers(): Record<string, string | null> {
    const result: Record<string, string | null> = {}
    for (const question of this.questions) {
      if (question.qid in result) continue
      result[question.qid] = clarifyAnswer(question, this.selection(question))
    }
    return result
  }

  /** Whether there is a question after the one on show. */
  get hasNext(): boolean {
    return this.activeIndex < this.questions.length - 1
  }

  show(index: number): ClarifyForm {
    return new ClarifyForm(this.request, this.selections, index)
  }

  /**
   * Picks a choice. A single-select question takes it in place of anything picked or
   * typed before, and the card moves on to the next unanswered question; a multi-select
   * one toggles it (kept in the order offered) and keeps the typed text.
   */
  pick(choice: string, question: ClarifyQuestion): ClarifyForm {
    const selection = this.selection(question)
    const selections = new Map(this.selections)
    if (allowsMultipleClarifyChoices(question)) {
      const choices = selection.choices.includes(choice)
        ? selection.choices.filter((picked) => picked !== choice)
        : offeredClarifyChoices(question).filter((offered) => selection.choices.includes(offered) || offered === choice)
      selections.set(question.qid, { ...selection, choices })
      return new ClarifyForm(this.request, selections, this.activeIndex)
    }
    selections.set(question.qid, { choices: [choice], other: '' })
    const picked = new ClarifyForm(this.request, selections, this.activeIndex)
    return picked.advanced(question)
  }

  /** The typed answer. On a single-select question typed text replaces the picked choice. */
  setOther(text: string, question: ClarifyQuestion): ClarifyForm {
    const selection = this.selection(question)
    const selections = new Map(this.selections)
    const clears = !allowsMultipleClarifyChoices(question) && text !== ''
    selections.set(question.qid, { choices: clears ? [] : selection.choices, other: text })
    return new ClarifyForm(this.request, selections, this.activeIndex)
  }

  /** Shows the next unanswered question after `question`; stays put when every later one is answered. */
  private advanced(question: ClarifyQuestion): ClarifyForm {
    const index = this.questions.findIndex((other) => other.qid === question.qid)
    if (index < 0) return this
    for (let next = index + 1; next < this.questions.length; next += 1) {
      if (!this.isAnswered(this.questions[next]!)) return this.show(next)
    }
    return this
  }
}
