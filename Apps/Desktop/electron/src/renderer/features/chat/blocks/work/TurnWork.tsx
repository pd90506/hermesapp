import { useEffect, useRef, useState } from 'react'
import {
  StepGroups, ToolCallViews, WorkSteps, blockKind, settledTitle, toolCallView, workDuration, workingTitle,
  type ChatSession, type StepGroup, type TranscriptBlock, type TranscriptItem, type TurnWork, type WorkStep,
} from '@talaria/hermes-core'
import { useSnapshot } from '../../../../app/hooks.ts'
import { blockRenderer, type BlockProps } from '../registry.ts'
import { Markdown } from '../../../markdown/Markdown.tsx'
import { FoldButton } from './Fold.tsx'
import { InTurnWork, remember, rememberedValue, useRemembered } from './remembered.ts'
import { CopyButton, ToolCallBody, stepOutputMaxLines } from './ToolCall.tsx'
import { WorkIcon, WorkSpinner, toolIcon } from './WorkIcon.tsx'
import styles from './Work.module.css'

/**
 * A turn's work before its answer (`TurnWork`), in the three layers the user asked for
 * (PR #59): one line, "Completed in 45s" (live: "Working… 12s"), with a thin rule under
 * it and the answer below; opened, under the rule, the turn's commentary and groups of
 * steps; a group opened, its steps, each opening in place to a card. Open one layer (its
 * groups and text, groups closed) while the turn works, closed once it is done, until the
 * user opens or closes it.
 */
export function TurnWorkBlock({ block, chat }: BlockProps) {
  if (block.kind !== 'work') return null
  return <TurnWorkView work={block.work} chat={chat} />
}

function TurnWorkView({ work, chat }: { work: TurnWork; chat: ChatSession }) {
  // The user's choice; until then open exactly while the turn works.
  const [toggled, setToggled] = useRemembered<boolean | undefined>(chat, `work:${work.id}`, undefined)
  const open = toggled ?? work.isLive
  return (
    <div className={styles.work} data-testid="turn-work">
      <FoldButton expanded={open} onToggle={setToggled} chevron="upDown" className={styles.workLine}>
        <WorkTitle work={work} chat={chat} />
      </FoldButton>
      <div className={styles.rule} />
      {open && (
        <InTurnWork.Provider value={true}>
          <div className={styles.entries}>
            {work.entries.map((entry) => {
              if (entry.kind === 'group') return <StepGroupView key={entry.id} group={entry.group} chat={chat} />
              return <Message key={entry.id} item={entry.item} chat={chat} />
            })}
          </div>
        </InTurnWork.Provider>
      )}
    </div>
  )
}

/** A row of the work drawn as the chat draws it alone: commentary as a reply, a card call as a tool row. */
function Message({ item, chat }: { item: TranscriptItem; chat: ChatSession }) {
  const block: TranscriptBlock = { kind: 'item', id: item.id, item }
  const Renderer = blockRenderer(blockKind(block))
  return Renderer ? <Renderer block={block} chat={chat} isNewest={false} /> : null
}

/** "Working… 12s", counting each second; once done, "Completed in 45s". */
function WorkTitle({ work, chat }: { work: TurnWork; chat: ChatSession }) {
  const [appeared] = useState(() => Date.now())
  const [now, setNow] = useState(() => Date.now())
  const settledKey = `work-settled:${work.id}`
  // When this view saw the work end, for a turn whose rows carry no time yet.
  const wasLive = useRef(work.isLive)
  if (wasLive.current !== work.isLive) {
    remember(chat, settledKey, work.isLive ? undefined : Date.now())
    wasLive.current = work.isLive
  }
  useEffect(() => {
    if (!work.isLive) return
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [work.isLive])
  if (work.isLive) return <span className={styles.workTitle}>{workingTitle(work.startedAt ?? appeared, now)}</span>
  // A turn this view saw end keeps the time its counter stopped at, so the line doesn't
  // change when the stored rows' times arrive a moment later; otherwise the rows' times.
  const settledAt = rememberedValue<number>(chat, settledKey)
  const seen = work.startedAt !== undefined && settledAt !== undefined && settledAt >= work.startedAt
    ? (settledAt - work.startedAt) / 1000
    : undefined
  const seconds = seen ?? workDuration(work)
  return <span className={styles.workTitle}>{settledTitle(seconds, work.wasInterrupted)}</span>
}

/**
 * A group of a turn's steps: its kind's icon and what its calls did ("Ran commands"), a
 * chevron only under the pointer; opened, its steps one line each. Closed until the user
 * opens it, also while the turn works in it. While the turn works in it, its line is its
 * newest step's ("Bash · git status"), changing as each step starts.
 */
function StepGroupView({ group, chat }: { group: StepGroup; chat: ChatSession }) {
  const [open, setOpen] = useRemembered(chat, `group:${group.id}`, false)
  const latest = StepGroups.liveStep(group)
  const tools = StepGroups.tools(group)
  const iconTool = StepGroups.iconTool(group)
  return (
    <div className={styles.group} data-testid="step-group">
      <FoldButton expanded={open} onToggle={setOpen} chevron="onHover" className={styles.groupLine}>
        {latest
          ? <WorkStepLine step={latest} />
          : (
            <span className={styles.groupTitle} title={tools.length === 0 ? undefined : StepGroups.summary(group)}>
              <span className={styles.glyph}><WorkIcon name={iconTool ? toolIcon(iconTool) : 'atom'} /></span>
              <span className={styles.title}>{StepGroups.title(group)}</span>
            </span>
          )}
      </FoldButton>
      {open && (
        <div className={styles.steps}>
          {group.steps.map((step) => <WorkStepView key={step.id} step={step} chat={chat} />)}
        </div>
      )}
    </div>
  )
}

/** One step: "Bash · git status", "Think · Checking the build", opening in place to its card. */
function WorkStepView({ step, chat }: { step: WorkStep; chat: ChatSession }) {
  const [open, setOpen] = useRemembered(chat, `step:${step.id}`, false)
  return (
    <div className={styles.step} data-testid="work-step">
      <FoldButton expanded={open} onToggle={setOpen} chevron="onHover" className={styles.stepLine}>
        <WorkStepLine step={step} />
      </FoldButton>
      {open && <WorkStepCard step={step} chat={chat} />}
    </div>
  )
}

/** A step's line: its icon (or its status while it runs or once it failed), its kind, a dot, and what it was about. */
function WorkStepLine({ step }: { step: WorkStep }) {
  const failed = WorkSteps.failed(step)
  const summary = WorkSteps.summary(step)
  const name = WorkSteps.toolName(step)
  return (
    <>
      <span className={styles.glyph}>
        {WorkSteps.isLive(step) ? <WorkSpinner /> : failed ? <WorkIcon name="alert" tone="critical" /> : <WorkIcon name={name ? toolIcon(name) : 'atom'} />}
      </span>
      <span className={styles.stepKind} data-tone={failed ? 'critical' : undefined}>{WorkSteps.kind(step)}</span>
      {summary !== '' && (
        <>
          <span className={styles.dot}>·</span>
          <span className={styles.stepSummary}>{summary}</span>
        </>
      )}
    </>
  )
}

/**
 * An opened step, the bottom layer: a rounded card whose top holds a status dot, the
 * working folder (or the call's title), the whole command in a monospaced font and a
 * Copy button; under a rule, the output, scrolling past a few lines. A call that is not
 * a command shows its title and what it opens to; reasoning shows in full.
 */
function WorkStepCard({ step, chat }: { step: WorkStep; chat: ChatSession }) {
  const view = step.kind === 'tool' ? toolCallView(step.item) : undefined
  const hasBody = view ? ToolCallViews.showsDetail(view) || view.detail !== '' || view.stdout !== undefined
    || view.stderr !== undefined || view.searchHits.length > 0 || view.inlineDiff !== '' : true
  return (
    <div className={styles.card} data-testid="work-step-card">
      <div className={styles.cardHeader}>
        <StepStatusDot step={step} />
        <div className={styles.cardHeading}>
          {view ? <ToolHeading step={step} chat={chat} /> : <span className={styles.cardLabel}>Reasoning</span>}
        </div>
        <CopyButton text={WorkSteps.copyText(step)} />
      </div>
      {hasBody && (
        <div className={styles.cardBody}>
          {view
            ? <ToolCallBody view={view} showsCommand={false} showsAllOutput outputMaxLines={stepOutputMaxLines} />
            : <div className={styles.reasoning}><Markdown text={step.item.reasoning} streaming={WorkSteps.isLive(step)} /></div>}
        </div>
      )}
    </div>
  )
}

function ToolHeading({ step, chat }: { step: WorkStep; chat: ChatSession }) {
  const view = toolCallView(step.item)
  const chatView = useSnapshot(chat)
  if (view.terminalCommand !== undefined) {
    const folder = folderName(WorkSteps.workdir(step) ?? chatView.info?.cwd ?? undefined)
    const exit = view.terminalExitCode
    return (
      <div className={styles.commandHeading}>
        <div className={styles.cardMeta}>
          {folder && <span>{folder}</span>}
          {exit !== undefined && exit !== 0 && <span className={styles.exitCode}>exit {exit}</span>}
          {!view.isPending && view.durationLabel && <span>{view.durationLabel}</span>}
        </div>
        <code className={styles.cardCommand}>{view.terminalCommand === '' ? WorkSteps.summary(step) : view.terminalCommand}</code>
      </div>
    )
  }
  return (
    <div className={styles.cardMeta}>
      <span className={styles.cardTitle}>{view.title}</span>
      {!view.isPending && view.countLabel && <span>{view.countLabel}</span>}
      {!view.isPending && view.durationLabel && <span>{view.durationLabel}</span>}
    </div>
  )
}

/** A step's status in its card: running, done, failed or a warning. */
function StepStatusDot({ step }: { step: WorkStep }) {
  if (WorkSteps.isLive(step)) return <span className={styles.cardStatus}><WorkSpinner /></span>
  let tone = 'neutral'
  if (step.kind === 'tool') {
    const status = toolCallView(step.item).status
    tone = status === 'error' ? 'critical' : status === 'warning' ? 'caution' : status === 'notice' ? 'neutral' : 'success'
  }
  return <span className={styles.cardStatus}><span className={styles.statusDot} data-tone={tone} /></span>
}

/** The last part of a folder's path, as the card names it. */
function folderName(path: string | undefined): string | undefined {
  const trimmed = path?.trim()
  if (!trimmed) return undefined
  const parts = trimmed.split(/[/\\]/).filter((part) => part !== '')
  return parts[parts.length - 1] ?? trimmed
}
