import { useCallback, useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { ReasoningEffort, modelChoiceID, modelDisplayName, type ChatComposer } from '@talaria/hermes-core'
import { useConnectionSnapshot, useSnapshot } from '../../../app/hooks.ts'
import type { ComposerSlotProps } from '../slots.ts'
import { MenuAction, MenuChoice, MenuNote, MenuSection, PillMenu } from './PillMenu.tsx'
import styles from './ModelControls.module.css'

function useIsConnected(): boolean {
  return useConnectionSnapshot().link.phase === 'connected'
}

/**
 * The composer's model pill (the Mac's `modelMenu`, Desktop's `ModelPill`): the chat's
 * model, opening the catalog grouped by provider with the current one checked, and
 * Reload Models. `/model` with no model opens it too. A switch Hermes holds back for
 * confirmation (an expensive model) asks first.
 *
 * It also loads the slash catalog and the model options when the chat shows and again
 * after a reconnect (the Mac composer's `loadCommandsAndOptions` task).
 */
export function ModelPill({ chat, composer }: ComposerSlotProps) {
  const isConnected = useIsConnected()
  const models = useSnapshot(composer.models)
  const sessionID = useSnapshot(chat).sessionID

  useEffect(() => {
    if (isConnected) void composer.loadCommandsAndOptions()
  }, [composer, sessionID, isConnected])

  const setOpen = useCallback((open: boolean) => composer.models.requestPicker(open), [composer])
  const current = composer.models.currentModel
  const label = composer.models.currentModelLabel ?? 'Model'
  const { catalog } = models

  return (
    <>
      <PillMenu label={label} accessibleLabel="Model" wide disabled={!isConnected} open={models.isPickerRequested}
        onOpenChange={setOpen} title={current ? `Model for this chat: ${current}` : 'Model for this chat'}
        footer={<MenuAction label="Reload Models" busy={models.isReloading} disabled={models.isReloading}
          onSelect={() => void composer.models.loadOptions(true)} />}>
        {catalog && !catalog.isEmpty ? catalog.providers.map((provider) => (
          <MenuSection key={provider.slug} title={provider.name}>
            {provider.models.map((model) => {
              const choice = { provider: provider.slug, model }
              return <MenuChoice key={modelChoiceID(choice)} label={modelDisplayName(model)} detail={model}
                checked={composer.models.isCurrent(choice)} onSelect={() => void composer.models.selectModel(choice)} />
            })}
          </MenuSection>
        )) : <MenuNote>{catalog ? 'No models available' : 'Loading models…'}</MenuNote>}
      </PillMenu>
      {models.pendingSwitch && <SwitchModelDialog composer={composer} />}
    </>
  )
}

/** The composer's effort pill (the Mac's `effortMenu`): hidden when the model has no reasoning control. */
export function EffortPill({ chat, composer }: ComposerSlotProps) {
  const isConnected = useIsConnected()
  useSnapshot(composer.models)
  useSnapshot(chat)
  const [open, setOpen] = useState(false)
  useEffect(() => setOpen(false), [composer])
  const choices = composer.models.effortChoices
  if (choices.length === 0) return null
  const current = composer.models.currentEffort
  return (
    <PillMenu label={ReasoningEffort.label(current)} accessibleLabel="Reasoning effort" title="Reasoning effort for this chat"
      disabled={!isConnected} open={open} onOpenChange={setOpen}>
      <MenuSection title="Reasoning Effort">
        {choices.map((level) => (
          <MenuChoice key={level} label={ReasoningEffort.label(level)} checked={level === current}
            onSelect={() => void composer.models.selectEffort(level)} />
        ))}
      </MenuSection>
    </PillMenu>
  )
}

/**
 * "Switch model?": Hermes held a switch back until the user agrees (`confirm_required`,
 * e.g. an expensive model). The same in-window dialog on every platform.
 */
function SwitchModelDialog({ composer }: { composer: ChatComposer }) {
  const pending = useSnapshot(composer.models).pendingSwitch
  useEffect(() => {
    if (!pending) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') composer.models.cancelPendingSwitch()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [composer, pending])
  if (!pending) return null
  const name = modelDisplayName(pending.choice.model)
  return createPortal(
    <div className={styles.scrim} onPointerDown={(event) => { if (event.target === event.currentTarget) composer.models.cancelPendingSwitch() }}>
      <div className={styles.dialog} role="alertdialog" aria-modal="true" aria-labelledby="switch-model-title" aria-describedby="switch-model-message">
        <h2 id="switch-model-title" className={styles.title}>Switch model?</h2>
        <p id="switch-model-message" className={styles.message}>{pending.message}</p>
        <div className={styles.buttons}>
          <button type="button" className={styles.secondary} onClick={() => composer.models.cancelPendingSwitch()}>
            Keep Current Model
          </button>
          <button type="button" className={styles.primary} autoFocus onClick={() => void composer.models.confirmPendingSwitch()}>
            Switch to {name}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  )
}
