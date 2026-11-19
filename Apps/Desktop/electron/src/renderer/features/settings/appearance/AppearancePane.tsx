import {
  appearanceModeLabel, appearanceModes, colorThemeLabel, colorThemes, defaultTextSizes, textSizeRange,
  type ColorTheme, type TextKind,
} from '@talaria/hermes-core'
import { useEffect, useState } from 'react'
import { useModel, useSnapshot } from '../../../app/hooks.ts'
import type { AppearanceStore } from './appearance-store.ts'
import { ThemePreview } from './ThemePreview.tsx'
import styles from './AppearancePane.module.css'

/**
 * Settings ▸ Appearance, as the Mac's `AppearanceSettingsPane`: light, dark or the
 * system's look, the colour theme, the UI, content and code text sizes, a preview of
 * them all, and Restore Defaults (the look and the sizes; the theme stays).
 */
export function AppearancePane() {
  const store = useModel().appearanceSettings
  return <AppearanceForm store={store} />
}

/** The pane's form over a store (tests and the pane share it). */
export function AppearanceForm({ store }: { store: AppearanceStore }) {
  const { settings, colors } = useSnapshot(store)
  return (
    <div className={styles.form} data-testid="appearancePane">
      <Row label="Appearance:">
        <div className={styles.segmented} role="radiogroup" aria-label="Appearance">
          {appearanceModes.map((mode) => (
            <button
              key={mode}
              type="button"
              role="radio"
              aria-checked={settings.mode === mode}
              className={styles.segment}
              onClick={() => store.setMode(mode)}
            >
              {appearanceModeLabel(mode)}
            </button>
          ))}
        </div>
      </Row>

      <Row label="Theme:">
        <div className={styles.stack}>
          <div className={styles.swatches} role="radiogroup" aria-label="Theme">
            {colorThemes.map((theme) => (
              <Swatch key={theme} theme={theme} selected={colors.preset === theme} onPick={() => store.setTheme(theme)} />
            ))}
          </div>
          <p className={styles.note}>
            Hermes Desktop's themes, with Codex and Claude Code. They color the window, the sidebar and the chat, the
            accent colors buttons and marks, and replies take the theme's Markdown colors.
          </p>
        </div>
      </Row>

      <hr className={styles.divider} />

      <SizeRow store={store} kind="ui" label="UI text:" note="The sidebar, lists, tool calls and settings." />
      <SizeRow store={store} kind="content" label="Content text:" note="Messages and the composer." />
      <SizeRow store={store} kind="code" label="Code text:" note="Code blocks in replies." />

      <Row label="Preview:">
        <ThemePreview />
      </Row>

      <Row label="">
        <button type="button" className={styles.button} disabled={settings.isDefault} onClick={() => store.restoreDefaults()}>
          Restore Defaults
        </button>
      </Row>
    </div>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className={styles.row}>
      <div className={styles.label}>{label}</div>
      <div className={styles.control}>{children}</div>
    </div>
  )
}

/** A theme as its accent in a circle, its name under it (`ColorThemePicker.Swatch`). */
function Swatch({ theme, selected, onPick }: { theme: ColorTheme; selected: boolean; onPick: () => void }) {
  const label = colorThemeLabel(theme)
  return (
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      aria-label={label}
      title={label}
      className={styles.swatch}
      data-theme-swatch={theme}
      onClick={onPick}
    >
      <span className={styles.ring}>
        <span className={styles.circle} />
      </span>
      <span className={styles.swatchName}>{label}</span>
    </button>
  )
}

/** A size as a number field, "pt" and a stepper, what it sizes under it. */
function SizeRow({ store, kind, label, note }: { store: AppearanceStore; kind: TextKind; label: string; note: string }) {
  const { settings } = useSnapshot(store)
  const size = settings.size(kind, defaultTextSizes[kind])
  const [draft, setDraft] = useState(String(size))
  useEffect(() => setDraft(String(size)), [size])
  const commit = () => {
    const value = Number(draft)
    if (draft.trim() === '' || !Number.isFinite(value)) setDraft(String(size))
    else store.setSize(kind, value)
  }
  return (
    <Row label={label}>
      <div className={styles.stack}>
        <div className={styles.sizeLine}>
          <input
            className={styles.sizeField}
            data-custom={settings.isCustom(kind)}
            aria-label={label.replace(':', '')}
            inputMode="numeric"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onBlur={commit}
            onKeyDown={(event) => {
              if (event.key === 'Enter') commit()
              if (event.key === 'ArrowUp') { event.preventDefault(); store.setSize(kind, size + 1) }
              if (event.key === 'ArrowDown') { event.preventDefault(); store.setSize(kind, size - 1) }
            }}
          />
          <span className={styles.unit}>pt</span>
          <span className={styles.stepper}>
            <button type="button" aria-label={`Smaller ${label.replace(':', '')}`} disabled={size <= textSizeRange.lower}
              onClick={() => store.setSize(kind, size - 1)}>−</button>
            <button type="button" aria-label={`Larger ${label.replace(':', '')}`} disabled={size >= textSizeRange.upper}
              onClick={() => store.setSize(kind, size + 1)}>+</button>
          </span>
        </div>
        <p className={styles.note}>{note}</p>
      </div>
    </Row>
  )
}
