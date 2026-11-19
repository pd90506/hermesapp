import { useEffect, useRef, useState } from 'react'
import {
  blueprintFieldOptions, blueprintInitialValues, catalogOffers, cronDraftFrom, cronDraftProblem,
  cronDraftProblemMessages, cronFrequencies, cronFrequencyTitles, deliveryOptionTitle, deliveryOptions, describeError,
  frequencyHasTime, isDeliverField, newCronDraft, parseTargets, scheduleExpression, scheduleSummary, setDraftDelivery,
  toggleDelivery, weekdayNames,
  type CronBlueprint, type CronBlueprintField, type CronBoard, type CronFrequency, type CronJob, type CronJobDraft,
  type CronModelCatalog,
} from '@talaria/hermes-core'
import { useSnapshot } from '../../app/hooks.ts'
import styles from './CronJobEditor.module.css'

/** What the job editor is open for. */
export type CronEditorTarget = { kind: 'new' } | { kind: 'edit'; job: CronJob }

/**
 * New and Edit Cron Job: the Mac's `CronJobEditor` sheet (Desktop's `CronEditorDialog`,
 * `apps/desktop/src/app/cron/index.tsx`) as a modal dialog with a grouped form. A new job
 * can start from one of the server's blueprints, whose blanks replace the form. The
 * presets' time, weekday and day of the month can be picked, where Desktop fixes them at
 * 9:00 on Mondays and the 1st.
 */
export function CronJobEditor({ target, board, onClose }: {
  target: CronEditorTarget
  board: CronBoard
  onClose: () => void
}) {
  const cron = useSnapshot(board)
  const isNew = target.kind === 'new'
  const [draft, setDraft] = useState<CronJobDraft>(() => target.kind === 'edit' ? cronDraftFrom(target.job) : newCronDraft())
  const [blueprintKey, setBlueprintKey] = useState<string>()
  const [blueprintValues, setBlueprintValues] = useState<Record<string, string>>({})
  const [catalog, setCatalog] = useState<CronModelCatalog>()
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string>()
  const ref = useRef<HTMLDialogElement>(null)
  const blueprint = cron.blueprints.find((item) => item.key === blueprintKey)

  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal?.()
  }, [])

  useEffect(() => {
    let live = true
    void (async () => {
      await board.loadBlueprints()
      await board.loadDeliveryTargets()
      if (draft.isScriptOnly) return
      try {
        const read = await board.modelCatalog()
        if (live) setCatalog(read)
      } catch {}
    })()
    return () => { live = false }
    // Read once, when the editor opens.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [board])

  const pick = (key: string | undefined) => {
    setBlueprintKey(key)
    const picked = cron.blueprints.find((item) => item.key === key)
    setBlueprintValues(picked ? blueprintInitialValues(picked) : {})
    setError(undefined)
  }

  const save = async () => {
    setError(undefined)
    if (!blueprint) {
      const problem = cronDraftProblem(draft)
      if (problem) {
        setError(cronDraftProblemMessages[problem])
        return
      }
    }
    setSaving(true)
    try {
      if (blueprint) await board.createFromBlueprint(blueprint, blueprintValues)
      else if (target.kind === 'edit') await board.save(target.job, draft)
      else await board.create(draft)
      onClose()
    } catch (failure) {
      setError(describeError(failure))
      setSaving(false)
    }
  }

  const title = isNew ? 'New Cron Job' : 'Edit Cron Job'
  return (
    <dialog ref={ref} className={styles.dialog} aria-label={title} data-testid="cronEditor"
      onCancel={(event) => { event.preventDefault(); if (!saving) onClose() }}>
      <form className={styles.form} onSubmit={(event) => { event.preventDefault(); void save() }}>
        <h2 className={styles.heading}>{title}</h2>
        <div className={styles.scroll}>
          {isNew && cron.blueprints.length > 0 && (
            <fieldset className={styles.group}>
              <label className={styles.row}>
                <span className={styles.label}>Start From</span>
                <select className={styles.control} value={blueprintKey ?? ''} data-testid="cronEditorStartFrom"
                  onChange={(event) => pick(event.target.value || undefined)}>
                  <option value="">Custom</option>
                  {cron.blueprints.map((item) => (
                    <option key={item.key} value={item.key}>{item.plugin ? `${item.title} · ${item.plugin}` : item.title}</option>
                  ))}
                </select>
              </label>
              {blueprint?.description && <p className={styles.footer}>{blueprint.description}</p>}
            </fieldset>
          )}
          {blueprint
            ? <BlueprintFields blueprint={blueprint} values={blueprintValues} onChange={setBlueprintValues}
                deliveryOptionsFor={(deliver) => deliveryOptions(cron.targets, deliver)} />
            : <JobFields draft={draft} onChange={setDraft} catalog={catalog}
                deliveryOptionsFor={(deliver) => deliveryOptions(cron.targets, deliver)} />}
          {error && <p className={styles.error} role="alert" data-testid="cronEditorError">{error}</p>}
        </div>
        <div className={styles.actions}>
          <button type="button" className={styles.button} disabled={saving} onClick={onClose}>Cancel</button>
          <button type="submit" className={styles.primary} disabled={saving} data-testid="cronEditorSave">
            {saving ? 'Saving…' : isNew ? 'Create' : 'Save'}
          </button>
        </div>
      </form>
    </dialog>
  )
}

type DeliveryOptionsFor = (deliver: string | undefined) => ReturnType<typeof deliveryOptions>

function JobFields({ draft, onChange, catalog, deliveryOptionsFor }: {
  draft: CronJobDraft
  onChange: (draft: CronJobDraft) => void
  catalog: CronModelCatalog | undefined
  deliveryOptionsFor: DeliveryOptionsFor
}) {
  const schedule = draft.schedule
  const setSchedule = (change: Partial<CronJobDraft['schedule']>) => onChange({ ...draft, schedule: { ...schedule, ...change } })
  const summary = scheduleSummary(schedule)
  const weekdays = weekdayNames()
  return (
    <>
      <fieldset className={styles.group}>
        <label className={styles.row}>
          <span className={styles.label}>Name</span>
          <input className={styles.control} value={draft.name} placeholder="Optional" data-testid="cronEditorName"
            onChange={(event) => onChange({ ...draft, name: event.target.value })} />
        </label>
        <label className={styles.stack}>
          <span className={styles.label}>Prompt</span>
          <textarea className={styles.prompt} value={draft.prompt} rows={3} data-testid="cronEditorPrompt"
            placeholder={draft.isScriptOnly ? 'Optional for a script' : 'What should Hermes do?'}
            onChange={(event) => onChange({ ...draft, prompt: event.target.value })} />
        </label>
        {draft.isScriptOnly && (
          <p className={styles.footer}>This job runs a script without an agent, so it uses no prompt or model.</p>
        )}
      </fieldset>

      <h3 className={styles.groupTitle}>Schedule</h3>
      <fieldset className={styles.group}>
        <label className={styles.row}>
          <span className={styles.label}>Repeat</span>
          <select className={styles.control} value={schedule.frequency} data-testid="cronEditorFrequency"
            onChange={(event) => setSchedule({ frequency: event.target.value as CronFrequency })}>
            {cronFrequencies.map((frequency) => <option key={frequency} value={frequency}>{cronFrequencyTitles[frequency]}</option>)}
          </select>
        </label>
        {schedule.frequency === 'weekly' && (
          <label className={styles.row}>
            <span className={styles.label}>Day</span>
            <select className={styles.control} value={schedule.weekday}
              onChange={(event) => setSchedule({ weekday: Number(event.target.value) })}>
              {weekdays.map((name, day) => <option key={day} value={day}>{name}</option>)}
            </select>
          </label>
        )}
        {schedule.frequency === 'monthly' && (
          <label className={styles.row}>
            <span className={styles.label}>Day of Month</span>
            <select className={styles.control} value={schedule.dayOfMonth}
              onChange={(event) => setSchedule({ dayOfMonth: Number(event.target.value) })}>
              {Array.from({ length: 28 }, (_, index) => index + 1).map((day) => <option key={day} value={day}>{day}</option>)}
            </select>
          </label>
        )}
        {schedule.frequency === 'hourly' && (
          <label className={styles.row}>
            <span className={styles.label}>Minute</span>
            <select className={styles.control} value={schedule.minute}
              onChange={(event) => setSchedule({ minute: Number(event.target.value) })}>
              {hourlyMinutes(schedule.minute).map((minute) => (
                <option key={minute} value={minute}>{`:${String(minute).padStart(2, '0')}`}</option>
              ))}
            </select>
          </label>
        )}
        {schedule.frequency === 'custom' && (
          <label className={styles.row}>
            <span className={styles.label}>Schedule</span>
            <input className={`${styles.control} ${styles.mono}`} value={schedule.custom} placeholder="0 9 * * 1-5"
              spellCheck={false} autoCorrect="off" autoCapitalize="off" data-testid="cronEditorCustomSchedule"
              onChange={(event) => setSchedule({ custom: event.target.value })} />
          </label>
        )}
        {frequencyHasTime(schedule.frequency) && (
          <label className={styles.row}>
            <span className={styles.label}>Time</span>
            <input className={styles.control} type="time" value={clock(schedule.hour, schedule.minute)}
              onChange={(event) => {
                const parsed = parseClock(event.target.value)
                if (parsed) setSchedule(parsed)
              }} />
          </label>
        )}
      </fieldset>
      <div className={styles.footer}>
        <p>{summary ? `${summary}  ·  ${scheduleExpression(schedule)}`
          : 'A cron expression (minute hour day month weekday), or “every 2h”, “30m”, or a date and time.'}</p>
        <p>Times are in the Hermes server's time zone.</p>
      </div>

      <DeliverySection options={deliveryOptionsFor(draft.deliver)} selected={parseTargets(draft.deliver)}
        onToggle={(id, on) => onChange(setDraftDelivery(draft, id, on))} />

      {!draft.isScriptOnly && (
        <>
          <fieldset className={styles.group}>
            <label className={styles.row}>
              <span className={styles.label}>Model</span>
              <select className={styles.control} data-testid="cronEditorModel"
                value={draft.model ? modelKey(draft.model.provider, draft.model.model) : ''}
                onChange={(event) => {
                  const choice = parseModelKey(event.target.value)
                  const { model: _, ...rest } = draft
                  onChange(choice ? { ...rest, model: choice } : rest)
                }}>
                <option value="">Profile's default</option>
                {draft.model && !catalogOffers(catalog, draft.model.provider, draft.model.model) && (
                  // A pinned model the catalog no longer offers stays shown and picked.
                  <option value={modelKey(draft.model.provider, draft.model.model)}>{draft.model.model}</option>
                )}
                {catalog?.providers.filter((provider) => provider.authenticated !== false).map((provider) => (
                  <optgroup key={provider.slug} label={provider.name}>
                    {provider.models.map((model) => (
                      <option key={model} value={modelKey(provider.slug, model)}>{model}</option>
                    ))}
                  </optgroup>
                ))}
              </select>
            </label>
          </fieldset>
          <p className={styles.footer}>A job without its own model uses the profile's default when it runs.</p>
        </>
      )}
    </>
  )
}

function DeliverySection({ options, selected, onToggle }: {
  options: ReturnType<typeof deliveryOptions>
  selected: string[]
  onToggle: (id: string, on: boolean) => void
}) {
  return (
    <>
      <h3 className={styles.groupTitle}>Deliver To</h3>
      <fieldset className={styles.group}>
        {options.map((target) => (
          <label key={target.id} className={styles.row} data-testid={`cronEditorDeliver.${target.id}`}>
            <span className={styles.label}>{deliveryOptionTitle(target)}</span>
            <input type="checkbox" className={styles.switch} role="switch" checked={selected.includes(target.id)}
              onChange={(event) => onToggle(target.id, event.target.checked)} />
          </label>
        ))}
      </fieldset>
    </>
  )
}

function BlueprintFields({ blueprint, values, onChange, deliveryOptionsFor }: {
  blueprint: CronBlueprint
  values: Record<string, string>
  onChange: (values: Record<string, string>) => void
  deliveryOptionsFor: DeliveryOptionsFor
}) {
  const fields = blueprint.fields.filter((field) => !isDeliverField(field))
  const deliver = blueprint.fields.find(isDeliverField)
  return (
    <>
      {fields.length > 0 && (
        <>
          <h3 className={styles.groupTitle}>{blueprint.title}</h3>
          <fieldset className={styles.group}>
            {fields.map((field) => (
              <BlueprintControl key={field.name} field={field} value={values[field.name] ?? ''}
                onChange={(value) => onChange({ ...values, [field.name]: value })} />
            ))}
          </fieldset>
        </>
      )}
      {deliver && (
        <DeliverySection options={deliveryOptionsFor(values[deliver.name])} selected={parseTargets(values[deliver.name])}
          onToggle={(id, on) => onChange({ ...values, [deliver.name]: toggleDelivery(values[deliver.name], id, on) })} />
      )}
    </>
  )
}

function BlueprintControl({ field, value, onChange }: {
  field: CronBlueprintField
  value: string
  onChange: (value: string) => void
}) {
  let control
  switch (field.kind) {
    case 'enum':
    case 'weekdays':
      control = (
        <select className={styles.control} value={value} onChange={(event) => onChange(event.target.value)}>
          {blueprintFieldOptions(field, value).map((option) => <option key={option} value={option}>{option}</option>)}
        </select>
      )
      break
    case 'time': {
      const parsed = parseClock(value) ?? { hour: 9, minute: 0 }
      control = (
        <input className={styles.control} type="time" value={clock(parsed.hour, parsed.minute)}
          onChange={(event) => { if (parseClock(event.target.value)) onChange(event.target.value) }} />
      )
      break
    }
    case 'text':
      control = (
        <input className={styles.control} value={value}
          placeholder={field.help || (field.isOptional ? 'Optional' : '')} onChange={(event) => onChange(event.target.value)} />
      )
  }
  return (
    <div>
      <label className={styles.row}>
        <span className={styles.label}>{field.label}</span>
        {control}
      </label>
      {field.kind !== 'text' && field.help && <p className={styles.help}>{field.help}</p>}
    </div>
  )
}

/** The hourly minutes the Mac offers (every 5), plus a stored one between them. */
function hourlyMinutes(current: number): number[] {
  const minutes = Array.from({ length: 12 }, (_, index) => index * 5)
  return minutes.includes(current) ? minutes : [...minutes, current].sort((a, b) => a - b)
}

/** `"HH:MM"`, as `<input type="time">` and a blueprint's time blank hold it: a wall-clock time. */
function clock(hour: number, minute: number): string {
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`
}

function parseClock(text: string): { hour: number; minute: number } | undefined {
  const match = /^(\d{1,2}):(\d{2})/.exec(text)
  if (!match) return undefined
  const hour = Number(match[1])
  const minute = Number(match[2])
  return hour <= 23 && minute <= 59 ? { hour, minute } : undefined
}

function modelKey(provider: string, model: string): string {
  return `${provider}\u0000${model}`
}

function parseModelKey(key: string): { provider: string; model: string } | undefined {
  const at = key.indexOf('\u0000')
  return at < 0 ? undefined : { provider: key.slice(0, at), model: key.slice(at + 1) }
}
