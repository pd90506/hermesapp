import type { JSONValue } from '../protocol/jsonrpc.ts'
import { deliveryTargets, isScriptOnly, toggleDelivery, type CronJob } from './job.ts'
import { defaultCronSchedule, parseCronSchedule, scheduleExpression, type CronSchedule } from './schedule.ts'

/** A model a job pins: a model id under the provider that serves it. */
export interface CronModelChoice {
  /** Provider slug; may be empty for a job that pinned only a model. */
  provider: string
  model: string
}

/**
 * The New and Edit Cron Job form: Desktop's `CronEditorDialog` fields
 * (`apps/desktop/src/app/cron/index.tsx:1209-1600`) and what it sends (HermesKit's
 * `CronJobDraft`).
 */
export interface CronJobDraft {
  name: string
  prompt: string
  schedule: CronSchedule
  /** Comma-separated delivery targets, `local` when none is picked. */
  deliver: string
  /** The job's own model; undefined follows the profile's default when it fires. */
  model?: CronModelChoice
  /** The job runs a script without an agent: the prompt is optional and no model applies. */
  readonly isScriptOnly: boolean
}

/** A new job: every day at 9:00, saved locally (Desktop's defaults). */
export function newCronDraft(): CronJobDraft {
  return { name: '', prompt: '', schedule: defaultCronSchedule(), deliver: 'local', isScriptOnly: false }
}

/** The job's current settings. */
export function cronDraftFrom(job: CronJob): CronJobDraft {
  const draft: CronJobDraft = {
    name: job.name ?? '',
    prompt: job.prompt ?? '',
    schedule: parseCronSchedule(job.scheduleExpression ?? ''),
    deliver: deliveryTargets(job).join(','),
    isScriptOnly: isScriptOnly(job),
  }
  if (job.model) draft.model = { provider: job.provider ?? '', model: job.model }
  return draft
}

export type CronDraftProblem = 'promptAndSchedule' | 'prompt' | 'schedule'

export const cronDraftProblemMessages: Readonly<Record<CronDraftProblem, string>> = {
  promptAndSchedule: 'Enter a prompt and a schedule.',
  prompt: 'Enter a prompt.',
  schedule: 'Enter a schedule.',
}

/** What keeps it from being saved (`validateCronEditor`, `cron-job-model.ts:25-42`). */
export function cronDraftProblem(draft: CronJobDraft): CronDraftProblem | undefined {
  const hasPrompt = draft.prompt.trim() !== ''
  const hasSchedule = scheduleExpression(draft.schedule) !== ''
  if (!hasSchedule && !hasPrompt && !draft.isScriptOnly) return 'promptAndSchedule'
  if (!hasSchedule) return 'schedule'
  if (!draft.isScriptOnly && !hasPrompt) return 'prompt'
  return undefined
}

/** The draft with `target` on or off; the last target stays. */
export function setDraftDelivery(draft: CronJobDraft, target: string, on: boolean): CronJobDraft {
  return { ...draft, deliver: toggleDelivery(draft.deliver, target, on) }
}

/**
 * `POST /api/cron/jobs` (`CronJobCreate`, `hermes_cli/web_models.py:316-336`; Desktop's
 * `handleEditorSave`, `index.tsx:605-628`): a model only when one is picked.
 */
export function cronCreateBody(draft: CronJobDraft): { [key: string]: JSONValue } {
  const body: { [key: string]: JSONValue } = {
    prompt: draft.prompt.trim(),
    schedule: scheduleExpression(draft.schedule),
    deliver: draft.deliver === '' ? 'local' : draft.deliver,
  }
  const name = draft.name.trim()
  if (name) body.name = name
  if (draft.model) {
    body.model = draft.model.model
    if (draft.model.provider) body.provider = draft.model.provider
  }
  return body
}

/**
 * `PUT /api/cron/jobs/{id}`'s `updates` (`cronEditorUpdates`, `cron-job-model.ts:137-158`):
 * a script-only job keeps an empty prompt and its stored model; an agent job always sends
 * both model fields, so picking the default clears a pinned one.
 */
export function cronDraftUpdates(draft: CronJobDraft): { [key: string]: JSONValue } {
  const updates: { [key: string]: JSONValue } = {
    deliver: draft.deliver,
    name: draft.name.trim(),
    schedule: scheduleExpression(draft.schedule),
  }
  const prompt = draft.prompt.trim()
  if (!draft.isScriptOnly || prompt !== '') updates.prompt = prompt
  if (!draft.isScriptOnly) {
    updates.model = draft.model ? draft.model.model : null
    updates.provider = draft.model && draft.model.provider ? draft.model.provider : null
  }
  return updates
}
