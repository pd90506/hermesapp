import { hitDate, snippetSegments, type SessionSearchResult } from '@talaria/hermes-core'
import { useEffect, useRef } from 'react'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { Icon } from '../../ui/Icon.tsx'
import { rowAge, useMinuteClock } from './age.ts'
import styles from './SessionSearch.module.css'

/** The search field over the list (the Mac's toolbar search field): focused when it opens; Escape on an empty field closes it. */
export function SearchField({ text, onChange, onClose, focusToken }: {
  text: string; onChange: (text: string) => void; onClose: () => void; focusToken: number
}) {
  const ref = useRef<HTMLInputElement>(null)
  useEffect(() => { ref.current?.focus() }, [focusToken])
  return (
    <div className={styles.field}>
      <Icon name="search" />
      <input ref={ref} type="search" className={styles.input} placeholder="Search chats" aria-label="Search chats"
        value={text} spellCheck={false} data-testid="sessionSearchField"
        onChange={(event) => onChange(event.target.value)}
        onBlur={() => { if (!text) onClose() }}
        onKeyDown={(event) => {
          if (event.key !== 'Escape') return
          event.preventDefault()
          if (text) onChange('')
          else onClose()
        }} />
    </div>
  )
}

/**
 * The search's results in the list's place while the field has text, as Mail's and the
 * Mac's: the profile's chats whose messages, title or id match, the best first. A search
 * per pause in typing (250 ms, Desktop waits 200).
 */
export function SessionSearchResults({ text }: { text: string }) {
  const model = useModel()
  const connection = useSnapshot(model.connection)
  const sidebar = useSnapshot(model.sidebar)
  const now = useMinuteClock()
  const query = text.trim()
  const profile = connection.selectedProfile
  useEffect(() => {
    const timer = setTimeout(() => void model.sidebar.search(query), query ? 250 : 0)
    return () => clearTimeout(timer)
  }, [model.sidebar, query, profile, connection.link.phase])
  const search = sidebar.search
  const selection = sidebar.selection

  let placeholder: { title: string; detail?: string; retry?: boolean } | undefined
  if (!search.available) placeholder = { title: 'Search Unavailable', detail: 'This server’s sign-in can’t read the dashboard.' }
  else if (search.error && search.query === query) placeholder = { title: 'Search Failed', detail: search.error, retry: true }
  else if (search.results.length === 0) {
    placeholder = search.searching || search.query !== query
      ? { title: 'Searching…' }
      : { title: `No Results for “${query}”`, detail: 'Check the spelling or try a new search.' }
  }

  return (
    <section className={styles.pane} aria-label="Search results" data-testid="sessionSearchResults">
      {search.results.length > 0 && (
        <div role="list">
          <h2 className={styles.section}>{search.results.length === 1 ? '1 chat' : `${search.results.length} chats`}</h2>
          {search.results.map((result) => profile && (
            <SearchRow key={result.row.id} result={result} now={now}
              selected={result.isBotChat ? selection?.kind === 'bot' && selection.profile === profile
                : selection?.kind === 'session' && selection.profile === profile && selection.id === result.row.id}
              onSelect={() => model.sidebar.select(result.isBotChat ? { kind: 'bot', profile }
                : { kind: 'session', profile, id: result.row.id })} />
          ))}
        </div>
      )}
      {placeholder && (
        <div className={styles.placeholder}>
          <p className={styles.placeholderTitle}>{placeholder.title}</p>
          {placeholder.detail && <p className={styles.placeholderDetail}>{placeholder.detail}</p>}
          {placeholder.retry && <button type="button" className={styles.retry} onClick={() => void model.sidebar.search(query)}>Try Again</button>}
        </div>
      )}
    </section>
  )
}

/** A hit (`SessionSearchRow`): the title, the matched text with the words in bold after whose message it is, and when. */
function SearchRow({ result, now, selected, onSelect }: {
  result: SessionSearchResult; now: number; selected: boolean; onSelect: () => void
}) {
  const title = result.isBotChat ? 'Bot Chat' : result.row.title?.trim() || 'Untitled chat'
  const segments = snippetSegments(result.hit.snippet)
  const speaker = result.hit.role === 'user' ? 'You' : result.hit.role === 'assistant' ? 'Hermes' : undefined
  const date = hitDate(result.hit)
  return (
    <div className={styles.row} role="listitem" tabIndex={0} aria-selected={selected} data-selected={selected || undefined}
      data-testid="sessionSearchRow" onClick={onSelect} onKeyDown={(event) => { if (event.key === 'Enter') onSelect() }}>
      <span className={styles.title}>{title}</span>
      {segments.length > 0 && (
        <span className={styles.snippet}>
          {speaker && `${speaker}: `}
          {segments.map((segment, index) => segment.isMatch ? <b key={index}>{segment.text}</b> : <span key={index}>{segment.text}</span>)}
        </span>
      )}
      {date !== undefined && <span className={styles.age}>{rowAge(date, now)}</span>}
    </div>
  )
}
