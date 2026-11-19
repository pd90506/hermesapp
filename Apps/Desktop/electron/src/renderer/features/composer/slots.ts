import type { ComponentType } from 'react'
import type { ChatComposer, ChatSession } from '@talaria/hermes-core'

/**
 * Extension point 2 (package A): the places in and over the composer other packages fill.
 * - `cards`: the stack of cards over the composer (package F: queued and held prompts,
 *   compression, clarify), the newest nearest the composer;
 * - `attachments`: above the text, inside the card (package E: image and file cards);
 * - `leading`: the toolbar's start (package E: the `+` menu);
 * - `modelEffort`: the toolbar, before the trailing buttons (package D: model and effort);
 * - `trailing`: just before Send / Stop (package D: the context gauge; voice later).
 */
export type ComposerSlotArea = 'cards' | 'attachments' | 'leading' | 'modelEffort' | 'trailing'

export interface ComposerSlotProps {
  chat: ChatSession
  composer: ChatComposer
}

export interface ComposerSlot {
  id: string
  area: ComposerSlotArea
  /** Within the area, start to end (for `cards`, top to bottom). */
  order: number
  Slot: ComponentType<ComposerSlotProps>
}

const slots: ComposerSlot[] = []

/** Registers a slot once, at import time; add an import line to `registered-slots.ts`. */
export function registerComposerSlot(slot: ComposerSlot): void {
  const index = slots.findIndex((other) => other.id === slot.id)
  if (index >= 0) slots.splice(index, 1)
  slots.push(slot)
  slots.sort((a, b) => a.order - b.order)
}

export function composerSlots(area: ComposerSlotArea): ComposerSlot[] {
  return slots.filter((slot) => slot.area === area)
}
