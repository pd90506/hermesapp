import { registerComposerSlot } from '../slots.ts'
import { PromptCards } from './PromptCards.tsx'

// Package F: the cards over the composer (compression, Hermes's queue, held messages).
registerComposerSlot({ id: 'f-prompt-cards', area: 'cards', order: 10, Slot: PromptCards })
