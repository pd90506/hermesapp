import { useEffect, useState, type CSSProperties } from 'react'
import { Icon } from '../../ui/Icon.tsx'
import { cachedHighlight, highlight, type HighlightedLine } from './highlight.ts'
import { copyText } from './clipboard.ts'
import styles from './Markdown.module.css'

/**
 * A code fence, as the Mac's `MarkdownCodeBlock`: the language at the top left, a Copy
 * button at the top right, and the code at its natural width in its own horizontal
 * scroll, never wrapped to the column. A fence still streaming in shows plain and takes
 * its colours once it closes, so a growing block is not re-highlighted per token.
 */
export function CodeBlock({ code, language, incomplete }: {
  code: string
  language?: string
  incomplete: boolean
}) {
  const text = code.replace(/\n$/, '')
  const [colours, setColours] = useState<{ text: string; lines?: HighlightedLine[] }>(
    () => ({ text, lines: cachedHighlight(text, language) }))
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (incomplete) return
    const ready = cachedHighlight(text, language)
    if (ready) { setColours({ text, lines: ready }); return }
    let current = true
    void highlight(text, language).then((lines) => {
      if (current) setColours({ text, lines })
    }).catch(() => undefined)
    return () => { current = false }
  }, [text, language, incomplete])

  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 1500)
    return () => clearTimeout(timer)
  }, [copied])

  // Colours only for the text they were made from: a fence that grew shows plain.
  const lines = !incomplete && colours.text === text ? colours.lines : undefined

  return (
    <div className={styles.codeBlock} data-markdown-code="">
      <div className={styles.codeHeader}>
        <span className={styles.codeLanguage}>{language ?? ''}</span>
        <button
          type="button"
          className={styles.codeCopy}
          title={copied ? 'Copied' : 'Copy code'}
          aria-label="Copy code"
          onClick={() => { void copyText(text).then((done) => setCopied(done)) }}
        >
          <Icon name={copied ? 'check' : 'copy'} />
        </button>
      </div>
      <div className={styles.codeScroll}>
        <pre className={styles.codePre}>
          <code>
            {lines
              ? lines.map((line, index) => (
                <span key={index} className={styles.codeLine}>
                  {line.tokens.map((token, at) => (
                    <span
                      key={at}
                      className={styles.token}
                      style={{ '--token-light': token.light, '--token-dark': token.dark } as CSSProperties}
                    >
                      {token.content}
                    </span>
                  ))}
                  {index < lines.length - 1 ? '\n' : null}
                </span>
              ))
              : text}
          </code>
        </pre>
      </div>
    </div>
  )
}
