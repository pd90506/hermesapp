import {
  Component, memo, useMemo, type ComponentProps, type ErrorInfo, type ReactNode,
} from 'react'
import { Streamdown, defaultRehypePlugins, defaultRemarkPlugins, useIsCodeFenceIncomplete, type Components } from 'streamdown'
import { createMathPlugin } from '@streamdown/math'
import 'katex/dist/katex.min.css'
import {
  cjkLanguageOf, externalLinkTarget, fenceLanguage, markdownCharacterLimit, normalizeMath, remarkKeepLineBreaks,
  type CJKLanguage,
} from '@talaria/hermes-core'
import { CodeBlock } from './CodeBlock.tsx'
import { WebImage } from '../chat/blocks/media/Embeds.tsx'
import styles from './Markdown.module.css'

/**
 * A message's Markdown: headings, emphasis, lists and task boxes, quotes, code fences
 * with a Copy button and syntax colours, inline and display maths (KaTeX), tables,
 * rules and links, as the Mac app draws them (`MarkdownView`), all selectable.
 *
 * Built on Streamdown (the official Desktop's renderer), which splits the text into
 * blocks and re-renders only the block that changed, and repairs the half-written
 * Markdown at a streaming message's end. Only a `streaming` message re-parses as it
 * grows; a finished one is memoized on its text. HermesKit's maths rules run first
 * (`normalizeMath`), so `$5 and $10` stays text on both apps.
 */
export const Markdown = memo(function Markdown({ text, streaming = false }: { text: string; streaming?: boolean }) {
  const source = useMemo(() => (text.length > markdownCharacterLimit ? text : normalizeMath(text, { streaming })), [text, streaming])
  const lang = useMemo(() => cjkLanguageOf(text, preferredCJK()), [text])

  if (text.length > markdownCharacterLimit) return <PlainText text={text} lang={lang} />
  return (
    <div className={styles.root} lang={lang} data-markdown="">
      <Fallback text={text} lang={lang}>
        <Streamdown
          mode="streaming"
          parseIncompleteMarkdown={streaming}
          isAnimating={streaming}
          animated={false}
          controls={false}
          linkSafety={{ enabled: false }}
          plugins={plugins}
          remarkPlugins={remarkPlugins}
          rehypePlugins={rehypePlugins}
          components={components}
        >
          {source}
        </Streamdown>
      </Fallback>
    </div>
  )
})

const plugins = { math: createMathPlugin({ singleDollarTextMath: true, errorColor: 'currentColor' }) }
const remarkPlugins = [...Object.values(defaultRemarkPlugins), remarkKeepLineBreaks]
// Streamdown's raw HTML and sanitizing, without its URL hardening: that one marks a
// relative link "[blocked]". Links here open only through `Link`, by `externalLinkTarget`.
const rehypePlugins = Object.entries(defaultRehypePlugins).filter(([name]) => name !== 'harden').map(([, plugin]) => plugin)

/** The system's CJK language, from the main process (`<html data-cjk>`). */
function preferredCJK(): CJKLanguage {
  const value = typeof document === 'undefined' ? undefined : document.documentElement.dataset.cjk
  return value === 'zh-Hant' || value === 'ja' || value === 'ko' ? value : 'zh-Hans'
}

function PlainText({ text, lang }: { text: string; lang: string | undefined }) {
  return <div className={`${styles.root} ${styles.plain}`} lang={lang} data-markdown="">{text}</div>
}

/** Content that breaks the parser shows as plain text; the rest of the transcript lives on. */
class Fallback extends Component<{ text: string; lang: string | undefined; children: ReactNode }, { failed: boolean }> {
  override state = { failed: false }

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true }
  }

  override componentDidCatch(error: unknown, info: ErrorInfo): void {
    console.warn('Markdown failed to render; showing plain text.', error, info.componentStack)
  }

  override render(): ReactNode {
    return this.state.failed ? <div className={styles.plain}>{this.props.text}</div> : this.props.children
  }
}

type Props<K extends keyof React.JSX.IntrinsicElements> = ComponentProps<K> & { node?: unknown }

/** Drops the parser's `node`, so it never reaches the DOM. */
function plain<K extends keyof React.JSX.IntrinsicElements>(tag: K, className?: string) {
  return function Element({ node: _node, ...props }: Props<K>) {
    const Tag = tag as React.ElementType
    return <Tag {...props} className={className} />
  }
}

function Link({ node: _node, href, children, title }: Props<'a'>) {
  const target = externalLinkTarget(href)
  if (!target) return <span className={styles.inertLink} title={href}>{children}</span>
  return (
    <a
      className={styles.link}
      href={target}
      title={title ?? target}
      onClick={(event) => {
        event.preventDefault()
        void window.talaria?.links.open(target)
      }}
    >
      {children}
    </a>
  )
}

/**
 * `![alt](src)`: a web image shows in place (Desktop's `MarkdownImage`); any other source
 * stays its link, as Hermes tells the model that local files go by `MEDIA:` only.
 */
function Image({ node: _node, alt, src }: Props<'img'>) {
  const url = typeof src === 'string' ? src.trim() : ''
  if (/^https?:\/\//i.test(url)) return <WebImage url={url} alt={typeof alt === 'string' ? alt : ''} />
  return <Link href={url || undefined}>{alt || url}</Link>
}

/** Fenced code (`data-block`, from Streamdown's `pre`) goes to `CodeBlock`. */
function Code({ node: _node, className, children, ...props }: Props<'code'> & { 'data-block'?: string }) {
  if (!('data-block' in props)) return <code className={styles.inlineCode}>{children}</code>
  return <Fence language={fenceLanguage(className)} code={typeof children === 'string' ? children : textOf(children)} />
}

function Fence({ language, code }: { language: string | undefined; code: string }) {
  const incomplete = useIsCodeFenceIncomplete()
  return <CodeBlock code={code} language={language} incomplete={incomplete} />
}

function textOf(node: ReactNode): string {
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(textOf).join('')
  if (node && typeof node === 'object' && 'props' in node) {
    return textOf((node.props as { children?: ReactNode }).children)
  }
  return ''
}

interface HastElement { tagName?: string; properties?: Record<string, unknown>; children?: HastElement[] }

/** A task item's box (`- [x]`) is its marker, ☐ or ☑ as on the Mac. */
function ListItem({ node, children, className }: Props<'li'>) {
  const element = node as HastElement | undefined
  const task = String(className ?? '').includes('task-list-item')
  const box = task ? element?.children?.find((child) => child.tagName === 'input') : undefined
  const state = box ? (box.properties?.checked ? 'done' : 'open') : undefined
  return <li className={styles.item} data-task={state}>{children}</li>
}

/**
 * A table as the Mac's `MarkdownTableGrid`: the column's full width, a rounded border,
 * a tinted header row, a rule between rows. Long cells wrap down to 10 em first; a table
 * that still does not fit reaches into the window's spare width (`--md-table-reach`),
 * centered on the column, only as far as it needs, and then scrolls sideways.
 */
function Table({ node: _node, children }: Props<'table'>) {
  return (
    <div className={styles.tableReach} data-markdown-table="">
      <div className={styles.tableScroll}>
        <table className={styles.table}>{children}</table>
      </div>
    </div>
  )
}

function Cell({ tag, node: _node, children, style }: Props<'td'> & { tag: 'td' | 'th' }) {
  const Tag = tag
  const align = style?.textAlign
  return (
    <Tag className={tag === 'th' ? styles.headerCell : styles.cell} data-align={align}>
      <div className={styles.cellText}>{children}</div>
    </Tag>
  )
}

const components: Components = {
  h1: plain('h1', styles.h1),
  h2: plain('h2', styles.h2),
  h3: plain('h3', styles.h3),
  h4: plain('h4', styles.h4),
  h5: plain('h5', styles.h4),
  h6: plain('h6', styles.h4),
  p: plain('p', styles.paragraph),
  strong: plain('strong', styles.strong),
  em: plain('em'),
  del: plain('del'),
  ul: plain('ul', styles.list),
  ol: plain('ol', styles.orderedList),
  li: ListItem,
  input: () => null,
  blockquote: plain('blockquote', styles.quote),
  hr: () => <div className={styles.rule} role="separator">────────</div>,
  a: Link,
  img: Image,
  code: Code,
  inlineCode: ({ children }: Props<'code'>) => <code className={styles.inlineCode}>{children}</code>,
  table: Table,
  thead: plain('thead'),
  tbody: plain('tbody'),
  tr: plain('tr', styles.row),
  th: (props: Props<'th'>) => <Cell tag="th" {...(props as Props<'td'>)} />,
  td: (props: Props<'td'>) => <Cell tag="td" {...props} />,
  sup: plain('sup'),
  sub: plain('sub'),
  section: plain('section', styles.footnotes),
}
