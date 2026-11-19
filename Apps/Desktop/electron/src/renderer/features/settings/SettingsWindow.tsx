import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { settingsWindowName } from '../../../shared/bridge.ts'
import { useModel, useSnapshot } from '../../app/hooks.ts'
import { SettingsView } from './SettingsView.tsx'
import './registered.ts'

/**
 * The Settings window (K): a native window of its own (its frame from the main process,
 * `src/main/ipc/settings-window.ts`), opened from this renderer with `window.open` and
 * drawn with a React portal, so its panes share this window's model and connections.
 * The window gets this document's styles and its root's attributes (platform, theme)
 * and follows them as they change.
 */
export function SettingsWindow() {
  const model = useModel()
  const { settings } = useSnapshot(model)
  const [child, setChild] = useState<Window | undefined>()
  const opened = useRef<Window | undefined>(undefined)

  useEffect(() => {
    if (!settings.open) {
      const current = opened.current
      opened.current = undefined
      setChild(undefined)
      if (current && !current.closed) current.close()
      return
    }
    if (opened.current && !opened.current.closed) return
    const target = window.open('about:blank', settingsWindowName)
    if (!target) {
      model.closeSettings()
      return
    }
    opened.current = target
    prepare(target)
    target.addEventListener('pagehide', () => {
      if (opened.current !== target) return
      opened.current = undefined
      setChild(undefined)
      model.closeSettings()
    })
    setChild(target)
  }, [settings.open, model])

  // Open again from the menu or the rail: the window comes forward.
  useEffect(() => model.onSettingsFocus(() => opened.current?.focus()), [model])

  // The window goes with the main window.
  useEffect(() => {
    const close = () => opened.current?.close()
    window.addEventListener('pagehide', close)
    return () => window.removeEventListener('pagehide', close)
  }, [])

  if (!child) return null
  return createPortal(<SettingsView />, child.document.body)
}

/** Gives the new window this document's styles and root attributes, and keeps them in step. */
function prepare(target: Window): void {
  const doc = target.document
  doc.title = 'Settings'
  const copyRoot = () => {
    const from = document.documentElement
    const to = doc.documentElement
    for (const name of to.getAttributeNames()) if (!from.hasAttribute(name)) to.removeAttribute(name)
    for (const name of from.getAttributeNames()) to.setAttribute(name, from.getAttribute(name) ?? '')
    to.dataset.window = 'settings'
  }
  const copyStyles = () => {
    for (const node of [...doc.head.querySelectorAll('[data-copied-style]')]) node.remove()
    for (const sheet of [...document.styleSheets]) {
      const owner = sheet.ownerNode as HTMLElement | null
      let text: string | undefined
      try {
        text = [...sheet.cssRules].map((rule) => rule.cssText).join('\n')
      } catch {}
      let copy: HTMLElement
      if (text !== undefined) {
        copy = doc.createElement('style')
        copy.textContent = text
      } else if (owner instanceof HTMLLinkElement) {
        const link = doc.createElement('link')
        link.rel = 'stylesheet'
        link.href = owner.href
        copy = link
      } else {
        continue
      }
      copy.dataset.copiedStyle = ''
      doc.head.appendChild(copy)
    }
  }
  copyRoot()
  copyStyles()
  const rootWatch = new MutationObserver(copyRoot)
  rootWatch.observe(document.documentElement, { attributes: true })
  // Styles added later (the dev server's hot updates, a lazily loaded module).
  const headWatch = new MutationObserver(copyStyles)
  headWatch.observe(document.head, { childList: true, subtree: true, characterData: true })
  target.addEventListener('pagehide', () => {
    rootWatch.disconnect()
    headWatch.disconnect()
  })
}

/** Reports the size of `element`'s content to the main process, which sizes the window to it. */
export function useWindowFitting(element: HTMLElement | null, report: (width: number, height: number) => void): void {
  useLayoutEffect(() => {
    if (!element) return
    const view = element.ownerDocument.defaultView
    if (!view) return
    const measure = () => {
      const box = element.getBoundingClientRect()
      report(Math.ceil(box.width), Math.ceil(box.height))
    }
    measure()
    const observer = new view.ResizeObserver(measure)
    observer.observe(element)
    return () => observer.disconnect()
  }, [element, report])
}
