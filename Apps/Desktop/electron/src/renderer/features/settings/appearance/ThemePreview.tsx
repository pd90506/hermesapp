import styles from './ThemePreview.module.css'

/**
 * The theme in a short exchange (the Mac's `ThemePreview`): the user's message in the
 * theme's bubble and a reply in its Markdown colours, at the content and code sizes.
 * Drawn here by hand from the Markdown tokens until the Markdown renderer (package B)
 * lands; then it renders `ThemePreview.sample` through it instead.
 */
export function ThemePreview() {
  return (
    <div className={styles.preview} data-testid="themePreview">
      <div className={styles.bubble}>Show me the themes.</div>
      <div className={styles.reply}>
        <h3 className={styles.heading}>A heading</h3>
        <p className={styles.paragraph}>
          Text with <strong className={styles.bold}>bold words</strong>, a <span className={styles.link}>link</span> and{' '}
          <code className={styles.inlineCode}>inline code</code>.
        </p>
        <blockquote className={styles.quote}>A quote stands apart from the reply.</blockquote>
        <table className={styles.table}>
          <thead>
            <tr><th>Name</th><th className={styles.number}>Value</th></tr>
          </thead>
          <tbody>
            <tr><td>Alpha</td><td className={styles.number}>1</td></tr>
            <tr><td>Beta</td><td className={styles.number}>2</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  )
}

/** The Mac's sample, for the Markdown renderer once it lands. */
ThemePreview.sample = `### A heading

Text with **bold words**, a [link](https://example.com) and \`inline code\`.

> A quote stands apart from the reply.

| Name | Value |
|------|------:|
| Alpha | 1 |
| Beta | 2 |
`
