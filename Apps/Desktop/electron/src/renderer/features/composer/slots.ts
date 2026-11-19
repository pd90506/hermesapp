import type { ComponentType, KeyboardEvent } from 'react'
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

/**
 * A key the composer's text area offers before its own handling (package D: the slash
 * list's arrows, Tab, Return and Esc). Return true when the handler took the key; the
 * composer then calls `preventDefault` and does nothing else with it. Never called while
 * an input method composes.
 */
export type ComposerKeyHandler = (event: KeyboardEvent<HTMLTextAreaElement>, props: ComposerSlotProps) => boolean

const keyHandlers: ComposerKeyHandler[] = []

/** Registers a key handler once, at import time, from a module `registered-slots.ts` imports. */
export function registerComposerKeyHandler(handler: ComposerKeyHandler): void {
  if (!keyHandlers.includes(handler)) keyHandlers.push(handler)
}

/** Offers the key to every registered handler, in registration order; true when one took it. */
export function handleComposerKey(event: KeyboardEvent<HTMLTextAreaElement>, props: ComposerSlotProps): boolean {
  return keyHandlers.some((handler) => handler(event, props))
}
