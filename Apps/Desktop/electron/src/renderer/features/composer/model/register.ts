// Package D's composer controls, registered once (registered-slots.ts imports this file).
// The toolbar reads as the Mac's: context gauge, model, effort, then Send.
import { ContextGaugeButton } from '../context/ContextGauge.tsx'
import { SlashList, slashKeys } from '../slash/SlashList.tsx'
import { registerComposerKeyHandler, registerComposerSlot } from '../slots.ts'
import { EffortPill, ModelPill } from './ModelControls.tsx'

registerComposerSlot({ id: 'd.slash', area: 'attachments', order: 0, Slot: SlashList })
registerComposerSlot({ id: 'd.context', area: 'modelEffort', order: 10, Slot: ContextGaugeButton })
registerComposerSlot({ id: 'd.model', area: 'modelEffort', order: 20, Slot: ModelPill })
registerComposerSlot({ id: 'd.effort', area: 'modelEffort', order: 30, Slot: EffortPill })
registerComposerKeyHandler(slashKeys)
