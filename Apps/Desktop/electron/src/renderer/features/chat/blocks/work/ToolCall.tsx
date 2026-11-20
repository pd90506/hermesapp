import { Fragment, useState, type ReactNode } from 'react'
import {
  ToolCallSummary, ToolCallViews, externalLinkTarget, toolCallView, type SearchHit, type ToolCallView,
} from '@talaria/hermes-core'
import type { BlockProps } from '../registry.ts'
import { Icon } from '../../../../ui/Icon.tsx'
import { copyText } from '../../../markdown/clipboard.ts'
import { FoldButton } from './Fold.tsx'
import { useRemembered } from './remembered.ts'
import { WorkIcon, WorkSpinner, toolIcon } from './WorkIcon.tsx'
import styles from './Work.module.css'

/**
 * One tool call on its own row (a call drawn as a card in a turn's work, or one outside
 * any turn), as Desktop's `ToolEntry` and the Mac's `ToolMessageContent` draw it: a line
 * (status or tool icon, what it did, counts and duration, chevron) that opens in place
 * into a bordered card: a command's `$` line and output, a file's lines, search hits, a
 * diff or an error. An edit with a diff opens by default; a settled edit with no diff
 * draws nothing.
 */
export function ToolBlock({ block, chat }: BlockProps) {
  const item = block.kind === 'item' ? block.item : undefined
  const view = item ? toolCallView(item) : undefined
  // The user's choice; until then an edit with a diff is open and the rest closed.
  const [toggled, setToggled] = useRemembered<boolean | undefined>(chat, `tool:${block.id}`, undefined)
  if (!item || !view || ToolCallViews.isHidden(view)) return null
  const expandable = ToolCallViews.isExpandable(view)
  const open = (toggled ?? ToolCallViews.opensByDefault(view)) && expandable
  return (
    <div className={styles.toolCall} data-open={open || undefined} data-testid="tool-call">
      <FoldButton expanded={open} onToggle={setToggled} chevron={expandable ? 'disclosure' : 'none'} disabled={!expandable}
        className={styles.toolCallLine}>
        <ToolCallLine view={view} />
      </FoldButton>
      {open && <div className={styles.toolCallBody}><ToolCallBody view={view} /></div>}
    </div>
  )
}

/** A tool call's line: its icon, title, result count, diff counts and duration. */
export function ToolCallLine({ view }: { view: ToolCallView }) {
  const stats = view.isFileEdit && !view.isPending && view.inlineDiff !== '' ? ToolCallViews.diffStats(view.inlineDiff) : undefined
  const tone = view.isPending ? 'pending' : view.status === 'error' ? 'critical' : view.status === 'warning' ? 'caution' : undefined
  return (
    <>
      <span className={styles.glyph}><ToolGlyph view={view} /></span>
      <span className={styles.title} data-tone={tone}>{view.title}</span>
      {!view.isPending && view.countLabel && <span className={styles.meta}>{view.countLabel}</span>}
      {stats && stats.added > 0 && <span className={styles.added}>+{stats.added}</span>}
      {stats && stats.removed > 0 && <span className={styles.removed}>−{stats.removed}</span>}
      {!view.isFileEdit && !view.isPending && view.durationLabel && <span className={styles.meta}>{view.durationLabel}</span>}
    </>
  )
}

/** A running, failed or unfinished call shows its status; any other its tool's icon. */
function ToolGlyph({ view }: { view: ToolCallView }) {
  if (view.isPending) return <WorkSpinner />
  if (view.status === 'error') return <WorkIcon name="alert" tone="critical" />
  if (view.status === 'warning') return <WorkIcon name="alert" tone="caution" />
  return <WorkIcon name={toolIcon(view.toolName)} />
}

/**
 * What an opened tool call shows, in Desktop's order: the `$` command, search hits, the
 * diff, then the detail (an error, a command's streams, or the output).
 */
export function ToolCallBody({ view, showsCommand = true, showsAllOutput = false, outputMaxLines }: {
  view: ToolCallView
  /** False where the command is shown above the body already (a step's card). */
  showsCommand?: boolean
  /** Shows the output even where it repeats the call's line: a step's card is where its output is read. */
  showsAllOutput?: boolean
  /** Output past this many lines scrolls; undefined for the box's own limit. */
  outputMaxLines?: number
}) {
  const command = view.terminalCommand
  const showsDetail = ToolCallViews.showsDetail(view) || (showsAllOutput && view.inlineDiff === '' && view.detail !== '')
  return (
    <div className={styles.callBody}>
      {showsCommand && command !== undefined && (command !== '' || view.terminalExitCode !== undefined) && (
        <TerminalCommandLine command={command} exitCode={view.terminalExitCode} />
      )}
      {view.searchHits.length > 0 && <SearchHitList query={view.searchQuery} hits={view.searchHits} />}
      {view.inlineDiff !== '' && <ToolTextBox text={view.inlineDiff} kind="diff" />}
      {showsDetail && <Detail view={view} outputMaxLines={outputMaxLines} />}
    </div>
  )
}

function Detail({ view, outputMaxLines }: { view: ToolCallView; outputMaxLines: number | undefined }) {
  if (view.status === 'error') {
    const summary = ToolCallViews.errorSummary(view)
    const body = ToolCallViews.detailBody(view)
    return (
      <div className={styles.section}>
        {summary !== '' && <div className={styles.errorSummary}>{summary}</div>}
        {body !== '' && <ToolTextBox text={body} kind="code" maxLines={errorMaxLines} />}
      </div>
    )
  }
  if (view.stdout !== undefined || view.stderr !== undefined) {
    return (
      <div className={styles.section}>
        <SectionLabel text={view.detailLabel} />
        {view.stdout !== undefined && (
          <>
            {view.stderr !== undefined && <SectionLabel text="stdout" />}
            <ToolTextBox text={ToolCallViews.stripANSI(view.stdout)} kind="code" maxLines={outputMaxLines} />
          </>
        )}
        {view.stderr !== undefined && (
          <>
            <SectionLabel text="stderr" />
            <ToolTextBox text={ToolCallViews.stripANSI(view.stderr)} kind="code" maxLines={outputMaxLines} muted />
          </>
        )}
      </div>
    )
  }
  return (
    <div className={styles.section}>
      <SectionLabel text={view.detailLabel} />
      {ToolCallViews.rendersDetailAsCode(view)
        ? <ToolTextBox text={ToolCallViews.stripANSI(view.detail)} kind="code" maxLines={outputMaxLines} />
        : <ToolTextBox text={view.detail} kind="text" maxLines={outputMaxLines} />}
    </div>
  )
}

/** A small heading over a section of an opened call ("stdout", "Error details"). */
function SectionLabel({ text }: { text: string }) {
  return text === '' ? null : <div className={styles.sectionLabel}>{text}</div>
}

/** `$ command` and its exit code, above a terminal call's output. */
function TerminalCommandLine({ command, exitCode }: { command: string; exitCode: number | undefined }) {
  return (
    <div className={styles.commandLine}>
      {command !== '' && <code className={styles.command}><span className={styles.prompt}>$</span> {command}</code>}
      {exitCode !== undefined && <span className={styles.exitCode} data-ok={exitCode === 0 || undefined}>exit {exitCode}</span>}
    </div>
  )
}

/** A web search's hits: the query, then each hit's title (a link) and snippet. */
function SearchHitList({ query, hits }: { query: string | undefined; hits: readonly SearchHit[] }) {
  return (
    <div className={styles.hits}>
      {query !== undefined && <div className={styles.hitQuery}><span className={styles.hitQueryLabel}>Search</span> {query}</div>}
      <SectionLabel text="Search results" />
      {hits.map((hit, index) => {
        const target = externalLinkTarget(hit.url)
        return (
        <div key={index} className={styles.hit}>
          {target
            ? (
              <a className={styles.hitTitle} href={target} title={target}
                onClick={(event) => { event.preventDefault(); void window.talaria?.links.open(target) }}>
                {hit.title === '' ? hit.url : hit.title}
              </a>
            )
            : <span className={styles.hitTitle}>{hit.title === '' ? hit.url : hit.title}</span>}
          {hit.snippet !== '' && <span className={styles.hitSnippet}>{hit.snippet}</span>}
        </div>
        )
      })}
    </div>
  )
}

/** A payload stops at 5 lines, a diff at 12 and an error at 14 before it scrolls (Desktop's 5rem / 12rem / 14rem). */
const outputMaxLines = 5
const diffMaxLines = 12
const errorMaxLines = 14
export const stepOutputMaxLines = 12

/**
 * A block of a call's text: code or output in a monospaced font, a diff in its colours,
 * other details as text. Past `maxLines` it scrolls inside itself.
 */
export function ToolTextBox({ text, kind, maxLines, muted = false }: {
  text: string
  kind: 'code' | 'text' | 'diff'
  maxLines?: number | undefined
  muted?: boolean
}) {
  const limit = maxLines ?? (kind === 'diff' ? diffMaxLines : outputMaxLines)
  const shown = ToolCallViews.clampForDisplay(kind === 'diff' ? ToolCallSummary.displayDiff(text) : text)
  const lines = shown.split('\n')
  const scrolls = lines.length > limit
  return (
    <div className={styles.textBox} data-kind={kind} data-muted={muted || undefined} data-scrolls={scrolls || undefined}
      style={scrolls ? { maxHeight: `calc(var(--work-box-line) * ${limit} + var(--work-box-padding-y) * 2)` } : undefined}>
      {kind === 'diff'
        ? lines.map((line, index) => (
          <Fragment key={index}>
            {index > 0 && '\n'}
            <span data-line={diffLineKind(line)}>{line}</span>
          </Fragment>
        ))
        : shown}
    </div>
  )
}

function diffLineKind(line: string): 'added' | 'removed' | undefined {
  if (line.startsWith('+') && !line.startsWith('+++')) return 'added'
  if (line.startsWith('-') && !line.startsWith('---')) return 'removed'
  return undefined
}

/** A borderless Copy button, "Copied" for a moment after a click. */
export function CopyButton({ text, label = 'Copy' }: { text: string; label?: string }): ReactNode {
  const [copied, setCopied] = useState(false)
  return (
    <button type="button" className={styles.copy} aria-label={label}
      onClick={() => {
        void copyText(text).then((done) => {
          setCopied(done)
          if (done) setTimeout(() => setCopied(false), 1500)
        })
      }}>
      <Icon name={copied ? 'check' : 'copy'} />
      <span>{copied ? 'Copied' : label}</span>
    </button>
  )
}
